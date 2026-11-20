//! The host process: owns every pseudo terminal, keeps each session's recent output, and serves the apps that
//! connect. It ends on its own once no app is connected and nothing runs.

use crate::endpoint::{self, Endpoint};
use crate::protocol::{Frame, Message, SessionInfo, SpawnSpec, VERSION};
use crate::scrollback::Scrollback;
use crate::Client;
use interprocess::local_socket::prelude::*;
use interprocess::local_socket::Stream;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub struct HostOptions {
    /// Where the endpoint file goes: the app's own state folder
    pub state_dir: PathBuf,
    /// How long the host waits, with no app connected and nothing running, before it ends
    pub idle_exit: Duration,
    /// Bytes of output kept per session for a reattaching app
    pub scrollback: usize,
}

impl HostOptions {
    pub fn new(state_dir: PathBuf) -> Self {
        Self {
            state_dir,
            idle_exit: Duration::from_secs(30),
            scrollback: 4 << 20,
        }
    }
}

/// Frames queued for one app before it counts as stuck and is let go
const QUEUE: usize = 4096;

struct Peer {
    tx: SyncSender<Frame>,
    /// Set when the app went away or fell too far behind; the connection is then closed
    gone: Arc<AtomicBool>,
}

impl Peer {
    /// Queues without waiting: a stuck app must not stall the terminals
    fn send(&self, frame: Frame) -> bool {
        if self.gone.load(Ordering::SeqCst) {
            return false;
        }
        match self.tx.try_send(frame) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                self.gone.store(true, Ordering::SeqCst);
                false
            }
        }
    }
}

struct Session {
    info: SessionInfo,
    /// Dropped shortly after the program ends: Windows' ConPTY closes its output only then
    master: Option<Box<dyn MasterPty + Send>>,
    writer: Option<Box<dyn Write + Send>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    scrollback: Scrollback,
    watchers: Vec<Arc<Peer>>,
    /// `exited` went out to the apps attached then
    exit_announced: bool,
}

impl Session {
    fn broadcast(&mut self, frame: &Frame) {
        self.watchers.retain(|p| p.send(frame.clone()));
    }
}

struct Shared {
    options: HostOptions,
    token: String,
    sessions: Mutex<HashMap<String, Arc<Mutex<Session>>>>,
    peers: AtomicUsize,
    idle_since: Mutex<Instant>,
}

impl Shared {
    fn session(&self, id: &str) -> Result<Arc<Mutex<Session>>, String> {
        self.sessions
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or_else(|| format!("No terminal session {id}"))
    }

    fn running(&self) -> usize {
        self.sessions
            .lock()
            .unwrap()
            .values()
            .filter(|s| s.lock().unwrap().info.running)
            .count()
    }
}

/// Runs the host until it has been idle for `idle_exit`. Fails with `AddrInUse` when a host already answers for
/// the same state folder.
pub fn serve(options: HostOptions) -> io::Result<()> {
    if Client::connect(&options.state_dir, |_| {}).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "A terminal host is already running",
        ));
    }
    let (listener, name, folder) = endpoint::listen()?;
    let me = Endpoint {
        version: VERSION,
        pid: std::process::id(),
        name,
        token: endpoint::random_hex(32)?,
    };
    me.write(&options.state_dir)?;
    let shared = Arc::new(Shared {
        token: me.token.clone(),
        options,
        sessions: Mutex::new(HashMap::new()),
        peers: AtomicUsize::new(0),
        idle_since: Mutex::new(Instant::now()),
    });
    loop {
        match listener.accept() {
            Ok(stream) => {
                // macOS hands the listener's non-blocking mode on to the accepted socket
                if stream.set_nonblocking(false).is_err() {
                    continue;
                }
                let shared = shared.clone();
                thread::spawn(move || serve_peer(stream, shared));
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50))
            }
            Err(_) => thread::sleep(Duration::from_millis(50)),
        }
        let busy = shared.peers.load(Ordering::SeqCst) > 0 || shared.running() > 0;
        let mut idle = shared.idle_since.lock().unwrap();
        if busy {
            *idle = Instant::now();
        } else if idle.elapsed() >= shared.options.idle_exit {
            break;
        }
    }
    me.remove(&shared.options.state_dir);
    drop(listener);
    if let Some(folder) = folder {
        let _ = std::fs::remove_dir_all(folder);
    }
    Ok(())
}

fn serve_peer(stream: Stream, shared: Arc<Shared>) {
    let stream = Arc::new(stream);
    let send = stream.clone();
    let mut recv = &*stream;
    let (tx, rx): (SyncSender<Frame>, Receiver<Frame>) = sync_channel(QUEUE);
    let gone = Arc::new(AtomicBool::new(false));
    let peer = Arc::new(Peer {
        tx,
        gone: gone.clone(),
    });
    // ends once every sender is dropped, or as soon as the app is let go
    let writer = thread::spawn(move || {
        for frame in rx {
            if gone.load(Ordering::SeqCst) || frame.write_to(&mut &*send).is_err() {
                gone.store(true, Ordering::SeqCst);
                break;
            }
        }
    });

    // the first frame proves the caller can read the endpoint file
    let welcome = match Frame::read_from(&mut recv) {
        Ok(Some(Frame::Control(Message::Hello { version, token }))) if token == shared.token => {
            if version == VERSION {
                Ok(())
            } else {
                Err(format!(
                    "The terminal host speaks version {VERSION}, the app {version}"
                ))
            }
        }
        _ => Err("The terminal host refused the connection".to_string()),
    };
    if let Err(message) = welcome {
        peer.send(Frame::Control(Message::Error { message }));
        drop(peer);
        let _ = writer.join();
        return;
    }
    peer.send(Frame::Control(Message::Welcome {
        version: VERSION,
        pid: std::process::id(),
    }));
    shared.peers.fetch_add(1, Ordering::SeqCst);

    while !peer.gone.load(Ordering::SeqCst) {
        match Frame::read_from(&mut recv) {
            Ok(Some(Frame::Data { id, bytes })) => {
                if let Ok(session) = shared.session(&id) {
                    if let Some(w) = session.lock().unwrap().writer.as_mut() {
                        let _ = w.write_all(&bytes).and_then(|_| w.flush());
                    }
                }
            }
            Ok(Some(Frame::Control(Message::Bye))) => break,
            Ok(Some(Frame::Control(message))) => match handle(&shared, &peer, message) {
                // an attach queues its reply itself, ahead of the replayed output
                Ok(Message::Attached { .. }) => {}
                Ok(reply) => {
                    peer.send(Frame::Control(reply));
                }
                Err(message) => {
                    peer.send(Frame::Control(Message::Error { message }));
                }
            },
            Ok(None) | Err(_) => break,
        }
    }

    for session in shared.sessions.lock().unwrap().values() {
        session
            .lock()
            .unwrap()
            .watchers
            .retain(|p| !Arc::ptr_eq(p, &peer));
    }
    shared.peers.fetch_sub(1, Ordering::SeqCst);
    *shared.idle_since.lock().unwrap() = Instant::now();
    peer.gone.store(true, Ordering::SeqCst);
    drop(peer);
    let _ = writer.join();
}

fn handle(shared: &Arc<Shared>, peer: &Arc<Peer>, message: Message) -> Result<Message, String> {
    match message {
        Message::List => {
            let mut sessions: Vec<SessionInfo> = shared
                .sessions
                .lock()
                .unwrap()
                .values()
                .map(|s| s.lock().unwrap().info.clone())
                .collect();
            sessions.sort_by(|a, b| (a.started, &a.id).cmp(&(b.started, &b.id)));
            Ok(Message::Sessions { sessions })
        }
        Message::Spawn { spec } => spawn(shared, spec),
        Message::Attach { id } => {
            let session = shared.session(&id)?;
            let mut s = session.lock().unwrap();
            let attached = Message::Attached {
                session: s.info.clone(),
            };
            // under the session's lock, so no output slips between the replay and the live stream
            peer.send(Frame::Control(attached.clone()));
            peer.send(Frame::Data {
                id: id.clone(),
                bytes: s.scrollback.snapshot(),
            });
            // an app that attaches after the ending was announced hears of it right after the replay
            if s.exit_announced {
                let exit_code = s.info.exit_code;
                peer.send(Frame::Control(Message::Exited { id, exit_code }));
            }
            if !s.watchers.iter().any(|p| Arc::ptr_eq(p, peer)) {
                s.watchers.push(peer.clone());
            }
            Ok(attached)
        }
        Message::Detach { id } => {
            shared
                .session(&id)?
                .lock()
                .unwrap()
                .watchers
                .retain(|p| !Arc::ptr_eq(p, peer));
            Ok(Message::Ok)
        }
        Message::Resize { id, cols, rows } => {
            let session = shared.session(&id)?;
            let mut s = session.lock().unwrap();
            let (cols, rows) = (cols.max(10), rows.max(2));
            if let Some(master) = s.master.as_ref() {
                master
                    .resize(PtySize {
                        rows,
                        cols,
                        pixel_width: 0,
                        pixel_height: 0,
                    })
                    .map_err(|e| e.to_string())?;
            }
            s.info.cols = cols;
            s.info.rows = rows;
            Ok(Message::Ok)
        }
        Message::Kill { id } => {
            let session = shared.session(&id)?;
            let mut s = session.lock().unwrap();
            if s.info.running {
                let _ = s.killer.kill();
            }
            Ok(Message::Ok)
        }
        Message::Forget { id } => {
            let mut sessions = shared.sessions.lock().unwrap();
            match sessions.get(&id) {
                Some(s) if s.lock().unwrap().info.running => {
                    Err("The terminal session is still running".into())
                }
                Some(_) => {
                    sessions.remove(&id);
                    Ok(Message::Ok)
                }
                None => Err(format!("No terminal session {id}")),
            }
        }
        _ => Err("The terminal host does not take this message".into()),
    }
}

fn spawn(shared: &Arc<Shared>, spec: SpawnSpec) -> Result<Message, String> {
    if shared.sessions.lock().unwrap().contains_key(&spec.id) {
        return Err(format!("The terminal session {} exists already", spec.id));
    }
    let (cols, rows) = (spec.cols.max(10), spec.rows.max(2));
    let pair = native_pty_system()
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| e.to_string())?;
    let mut cmd = CommandBuilder::new(&spec.program);
    cmd.args(&spec.args);
    cmd.cwd(&spec.cwd);
    for (k, v) in &spec.env {
        cmd.env(k, v);
    }
    let mut child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let pid = child.process_id();
    let killer = child.clone_killer();
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let started = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let info = SessionInfo {
        id: spec.id.clone(),
        pid,
        cols,
        rows,
        running: true,
        exit_code: None,
        started,
        meta: spec.meta,
    };
    let session = Arc::new(Mutex::new(Session {
        info,
        master: Some(pair.master),
        writer: Some(writer),
        killer,
        scrollback: Scrollback::new(shared.options.scrollback),
        watchers: Vec::new(),
        exit_announced: false,
    }));
    shared
        .sessions
        .lock()
        .unwrap()
        .insert(spec.id.clone(), session.clone());

    // the program's end: record it, then close the terminal so Windows' ConPTY lets the output reader finish
    let ended = Arc::new(AtomicBool::new(false));
    {
        let session = session.clone();
        let ended = ended.clone();
        thread::spawn(move || {
            let code = child.wait().ok().map(|s| s.exit_code() as i32);
            {
                let mut s = session.lock().unwrap();
                s.info.running = false;
                s.info.exit_code = code;
            }
            ended.store(true, Ordering::SeqCst);
            thread::sleep(Duration::from_millis(150));
            let mut s = session.lock().unwrap();
            s.writer = None;
            s.master = None;
        });
    }

    {
        let id = spec.id.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 16 * 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let mut s = session.lock().unwrap();
                        s.scrollback.push(&buf[..n]);
                        s.broadcast(&Frame::Data {
                            id: id.clone(),
                            bytes: buf[..n].to_vec(),
                        });
                    }
                }
            }
            // the exit code may be recorded a moment after the output ends
            for _ in 0..100 {
                if ended.load(Ordering::SeqCst) {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
            let mut s = session.lock().unwrap();
            let exit_code = s.info.exit_code;
            s.broadcast(&Frame::Control(Message::Exited { id, exit_code }));
            s.exit_announced = true;
        });
    }

    Ok(Message::Spawned { id: spec.id, pid })
}
