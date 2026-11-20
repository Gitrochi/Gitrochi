//! The app's side of the connection: requests wait for their reply, terminal output and endings arrive as events on
//! a reader thread.

use crate::endpoint::Endpoint;
use crate::protocol::{Frame, Message, SessionInfo, SpawnSpec, VERSION};
use interprocess::local_socket::Stream;
use std::io;
use std::path::Path;
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// A session's output; right after an attach, its replayed scrollback
    Output { id: String, bytes: Vec<u8> },
    /// An attached session's program ended
    Exited { id: String, exit_code: Option<i32> },
    /// The host went away
    Closed,
}

pub struct Client {
    stream: Arc<Stream>,
    /// One writer at a time, so frames never interleave
    sending: Mutex<()>,
    /// Held for a whole request, so each reply goes to the request that asked
    replies: Mutex<Receiver<Message>>,
    host_pid: u32,
}

impl Client {
    /// Connects to the host named in `state_dir`. Fails with `NotFound` or a connection error when none runs.
    pub fn connect(
        state_dir: &Path,
        on_event: impl Fn(Event) + Send + 'static,
    ) -> io::Result<Client> {
        let endpoint = Endpoint::read(state_dir)?;
        let stream = Arc::new(endpoint.connect()?);
        Frame::Control(Message::Hello {
            version: VERSION,
            token: endpoint.token,
        })
        .write_to(&mut &*stream)?;
        let host_pid = match Frame::read_from(&mut &*stream)? {
            Some(Frame::Control(Message::Welcome { pid, .. })) => pid,
            Some(Frame::Control(Message::Error { message })) => {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, message))
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "The terminal host did not answer",
                ))
            }
        };
        let (tx, rx) = channel();
        let reading = stream.clone();
        thread::spawn(move || {
            while let Ok(Some(frame)) = Frame::read_from(&mut &*reading) {
                match frame {
                    Frame::Data { id, bytes } => on_event(Event::Output { id, bytes }),
                    Frame::Control(Message::Exited { id, exit_code }) => {
                        on_event(Event::Exited { id, exit_code })
                    }
                    Frame::Control(reply) => {
                        if tx.send(reply).is_err() {
                            break;
                        }
                    }
                }
            }
            on_event(Event::Closed);
        });
        Ok(Client {
            stream,
            sending: Mutex::new(()),
            replies: Mutex::new(rx),
            host_pid,
        })
    }

    pub fn host_pid(&self) -> u32 {
        self.host_pid
    }

    fn request(&self, message: Message) -> io::Result<Message> {
        let replies = self.replies.lock().unwrap();
        self.write(Frame::Control(message))?;
        match replies.recv() {
            Ok(Message::Error { message }) => Err(io::Error::other(message)),
            Ok(reply) => Ok(reply),
            Err(_) => Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "The terminal host went away",
            )),
        }
    }

    fn expect_ok(&self, message: Message) -> io::Result<()> {
        match self.request(message)? {
            Message::Ok => Ok(()),
            other => Err(unexpected(other)),
        }
    }

    /// Every session the host keeps, oldest first, ended ones included until forgotten
    pub fn list(&self) -> io::Result<Vec<SessionInfo>> {
        match self.request(Message::List)? {
            Message::Sessions { sessions } => Ok(sessions),
            other => Err(unexpected(other)),
        }
    }

    /// Starts a program in a new session; returns its process id
    pub fn spawn(&self, spec: SpawnSpec) -> io::Result<Option<u32>> {
        match self.request(Message::Spawn { spec })? {
            Message::Spawned { pid, .. } => Ok(pid),
            other => Err(unexpected(other)),
        }
    }

    /// Starts receiving a session's output: first its scrollback, then what follows. Returns the session's state.
    pub fn attach(&self, id: &str) -> io::Result<SessionInfo> {
        match self.request(Message::Attach { id: id.into() })? {
            Message::Attached { session } => Ok(session),
            other => Err(unexpected(other)),
        }
    }

    pub fn detach(&self, id: &str) -> io::Result<()> {
        self.expect_ok(Message::Detach { id: id.into() })
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> io::Result<()> {
        self.expect_ok(Message::Resize {
            id: id.into(),
            cols,
            rows,
        })
    }

    pub fn kill(&self, id: &str) -> io::Result<()> {
        self.expect_ok(Message::Kill { id: id.into() })
    }

    pub fn forget(&self, id: &str) -> io::Result<()> {
        self.expect_ok(Message::Forget { id: id.into() })
    }

    /// Types into a session; not answered, so typing never waits on a request
    pub fn input(&self, id: &str, bytes: &[u8]) -> io::Result<()> {
        self.write(Frame::Data {
            id: id.into(),
            bytes: bytes.to_vec(),
        })
    }

    fn write(&self, frame: Frame) -> io::Result<()> {
        let _one = self.sending.lock().unwrap();
        frame.write_to(&mut &*self.stream)
    }
}

impl Drop for Client {
    /// The host closes its end, which also ends the reader thread
    fn drop(&mut self) {
        let _ = self.write(Frame::Control(Message::Bye));
    }
}

fn unexpected(reply: Message) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("Unexpected reply from the terminal host: {reply:?}"),
    )
}
