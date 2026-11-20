//! A real host on a private state folder: sessions outlive the app's connection and replay their output on reattach.

use gitrochi_terminal::{serve, Client, Endpoint, Event, HostOptions, SpawnSpec, ENDPOINT_FILE};
use serde_json::json;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

type Events = Arc<Mutex<Vec<Event>>>;

fn start_host(dir: &Path) -> JoinHandle<std::io::Result<()>> {
    let mut options = HostOptions::new(dir.to_path_buf());
    options.idle_exit = Duration::from_millis(500);
    let handle = thread::spawn(move || serve(options));
    until("the host to listen", || {
        Client::connect(dir, |_| {}).is_ok()
    });
    handle
}

fn connect(dir: &Path) -> (Client, Events) {
    let events: Events = Arc::default();
    let sink = events.clone();
    let client = Client::connect(dir, move |e| sink.lock().unwrap().push(e)).unwrap();
    (client, events)
}

fn until(what: &str, mut ready: impl FnMut() -> bool) {
    let start = Instant::now();
    while !ready() {
        assert!(
            start.elapsed() < Duration::from_secs(15),
            "timed out waiting for {what}"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

fn output(events: &Events, id: &str) -> String {
    let bytes: Vec<u8> = events
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            Event::Output { id: i, bytes } if i == id => Some(bytes.clone()),
            _ => None,
        })
        .flatten()
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn exited(events: &Events, id: &str) -> Option<Option<i32>> {
    events.lock().unwrap().iter().find_map(|e| match e {
        Event::Exited { id: i, exit_code } if i == id => Some(*exit_code),
        _ => None,
    })
}

/// Prints `ready`, then answers each typed line with `got:<line>`
fn echo_loop(id: &str) -> SpawnSpec {
    #[cfg(unix)]
    let (program, args) = (
        "/bin/sh",
        vec!["-c", "echo ready; while read l; do echo \"got:$l\"; done"],
    );
    #[cfg(windows)]
    let (program, args) = ("cmd.exe", vec!["/q", "/k", "echo ready"]);
    spec(id, program, &args)
}

#[cfg(unix)]
const TYPED: &[u8] = b"hello\n";
#[cfg(windows)]
const TYPED: &[u8] = b"echo got:hello\r\n";

fn spec(id: &str, program: &str, args: &[&str]) -> SpawnSpec {
    SpawnSpec {
        id: id.into(),
        program: program.into(),
        args: args.iter().map(|s| s.to_string()).collect(),
        cwd: std::env::temp_dir().to_string_lossy().into_owned(),
        env: Default::default(),
        cols: 80,
        rows: 24,
        meta: json!({ "repository": "demo", "title": "Shell" }),
    }
}

#[test]
fn sessions_outlive_the_app_and_replay_on_reattach() {
    let dir = tempfile::tempdir().unwrap();
    let host = start_host(dir.path());

    let (app, events) = connect(dir.path());
    assert!(app.spawn(echo_loop("tab-1")).unwrap().is_some());
    assert!(
        app.spawn(echo_loop("tab-1")).is_err(),
        "a second session with the same id"
    );
    app.attach("tab-1").unwrap();
    until("the first prompt", || {
        output(&events, "tab-1").contains("ready")
    });
    app.input("tab-1", TYPED).unwrap();
    until("the answer", || {
        output(&events, "tab-1").contains("got:hello")
    });
    app.resize("tab-1", 120, 40).unwrap();
    drop(app);

    // the app is gone; the program is not
    thread::sleep(Duration::from_millis(800));
    let (app, events) = connect(dir.path());
    let sessions = app.list().unwrap();
    assert_eq!(sessions.len(), 1);
    assert!(sessions[0].running);
    assert_eq!((sessions[0].cols, sessions[0].rows), (120, 40));
    assert_eq!(sessions[0].meta["repository"], "demo");

    let attached = app.attach("tab-1").unwrap();
    assert!(attached.running);
    until("the replay", || {
        let text = output(&events, "tab-1");
        text.contains("ready") && text.contains("got:hello")
    });

    app.kill("tab-1").unwrap();
    until("the ending", || exited(&events, "tab-1").is_some());
    assert!(!app.list().unwrap()[0].running);
    app.forget("tab-1").unwrap();
    assert!(app.list().unwrap().is_empty());
    assert!(app.attach("tab-1").is_err());

    drop(app);
    until("the idle host to end", || host.is_finished());
    host.join().unwrap().unwrap();
    assert!(!dir.path().join(ENDPOINT_FILE).exists());
}

#[test]
fn reports_the_exit_code_and_keeps_the_ended_session() {
    let dir = tempfile::tempdir().unwrap();
    let host = start_host(dir.path());
    let (app, events) = connect(dir.path());
    #[cfg(unix)]
    let ending = spec("t", "/bin/sh", &["-c", "sleep 0.3; echo bye; exit 3"]);
    #[cfg(windows)]
    let ending = spec(
        "t",
        "cmd.exe",
        &["/c", "ping -n 2 127.0.0.1 >nul & echo bye & exit 3"],
    );
    app.spawn(ending).unwrap();
    app.attach("t").unwrap();
    until("the ending", || exited(&events, "t").is_some());
    assert_eq!(exited(&events, "t"), Some(Some(3)));
    assert!(output(&events, "t").contains("bye"));
    drop(app);

    // an app that comes back later gets the output and then the ending
    let (app, events) = connect(dir.path());
    assert!(!app.attach("t").unwrap().running);
    until("the ending again", || exited(&events, "t").is_some());
    assert_eq!(exited(&events, "t"), Some(Some(3)));
    assert!(output(&events, "t").contains("bye"));
    assert!(app.forget("t").is_ok());
    drop(app);
    until("the idle host to end", || host.is_finished());
}

#[test]
fn turns_away_a_wrong_token_and_a_second_host() {
    let dir = tempfile::tempdir().unwrap();
    let host = start_host(dir.path());

    let mut second = HostOptions::new(dir.path().to_path_buf());
    second.idle_exit = Duration::from_millis(100);
    assert_eq!(
        serve(second).unwrap_err().kind(),
        std::io::ErrorKind::AddrInUse
    );

    let mut endpoint = Endpoint::read(dir.path()).unwrap();
    let real = std::fs::read(dir.path().join(ENDPOINT_FILE)).unwrap();
    endpoint.token = "0".repeat(64);
    std::fs::write(
        dir.path().join(ENDPOINT_FILE),
        serde_json::to_vec(&endpoint).unwrap(),
    )
    .unwrap();
    let refused = Client::connect(dir.path(), |_| {})
        .err()
        .expect("a wrong token must be refused");
    assert_eq!(refused.kind(), std::io::ErrorKind::PermissionDenied);
    std::fs::write(dir.path().join(ENDPOINT_FILE), real).unwrap();

    until("the idle host to end", || host.is_finished());
    host.join().unwrap().unwrap();
}
