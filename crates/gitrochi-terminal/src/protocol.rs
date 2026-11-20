//! Frames on the wire: a little-endian `u32` length of what follows, a kind byte, then the payload.
//! A control frame carries one JSON message; a data frame carries a session id and raw terminal bytes.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};

/// Bumped when a message changes shape; a client and a host of different versions refuse each other
pub const VERSION: u32 = 1;
/// Larger frames are refused rather than allocated
pub const MAX_FRAME: usize = 16 << 20;

const CONTROL: u8 = 0;
const DATA: u8 = 1;

/// What a session runs. `meta` is the app's own (repository, tab title, …): the host keeps it and lists it back.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SpawnSpec {
    pub id: String,
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub meta: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub pid: Option<u32>,
    pub cols: u16,
    pub rows: u16,
    pub running: bool,
    /// Set once the program has ended; `None` inside while it runs or when the code is unknown
    pub exit_code: Option<i32>,
    /// Seconds since the Unix epoch
    pub started: u64,
    pub meta: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Message {
    // client → host; each but `Bye` is answered, in order, by one reply below
    Hello {
        version: u32,
        token: String,
    },
    List,
    Spawn {
        spec: SpawnSpec,
    },
    /// Replies `Attached`, then the session's scrollback as one data frame, then its live output
    Attach {
        id: String,
    },
    Detach {
        id: String,
    },
    Resize {
        id: String,
        cols: u16,
        rows: u16,
    },
    Kill {
        id: String,
    },
    /// Drops an ended session from the list
    Forget {
        id: String,
    },
    /// Not answered: the host closes the connection; sessions keep running
    Bye,

    // host → client replies
    Welcome {
        version: u32,
        pid: u32,
    },
    Ok,
    Error {
        message: String,
    },
    Sessions {
        sessions: Vec<SessionInfo>,
    },
    Spawned {
        id: String,
        pid: Option<u32>,
    },
    Attached {
        session: SessionInfo,
    },

    // host → client, unasked: an attached session's program ended
    Exited {
        id: String,
        exit_code: Option<i32>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Frame {
    Control(Message),
    /// Output (host → client) or input (client → host) of one session
    Data {
        id: String,
        bytes: Vec<u8>,
    },
}

impl Frame {
    pub fn encode(&self) -> io::Result<Vec<u8>> {
        let mut body = Vec::new();
        match self {
            Frame::Control(message) => {
                body.push(CONTROL);
                serde_json::to_writer(&mut body, message).map_err(io::Error::other)?;
            }
            Frame::Data { id, bytes } => {
                let len =
                    u16::try_from(id.len()).map_err(|_| invalid("The session id is too long"))?;
                body.push(DATA);
                body.extend_from_slice(&len.to_le_bytes());
                body.extend_from_slice(id.as_bytes());
                body.extend_from_slice(bytes);
            }
        }
        if body.len() > MAX_FRAME {
            return Err(invalid("The frame is too large"));
        }
        let mut out = Vec::with_capacity(4 + body.len());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&body);
        Ok(out)
    }

    pub fn write_to(&self, w: &mut impl Write) -> io::Result<()> {
        w.write_all(&self.encode()?)?;
        w.flush()
    }

    /// The next frame, or `None` when the other side closed between frames
    pub fn read_from(r: &mut impl Read) -> io::Result<Option<Frame>> {
        let mut len = [0u8; 4];
        match r.read_exact(&mut len) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e),
        }
        let len = u32::from_le_bytes(len) as usize;
        if len == 0 || len > MAX_FRAME {
            return Err(invalid("The frame length is out of range"));
        }
        let mut body = vec![0u8; len];
        r.read_exact(&mut body)?;
        match body[0] {
            CONTROL => serde_json::from_slice(&body[1..])
                .map(|m| Some(Frame::Control(m)))
                .map_err(|e| invalid(&e.to_string())),
            DATA => {
                if body.len() < 3 {
                    return Err(invalid("The data frame is truncated"));
                }
                let id_len = u16::from_le_bytes([body[1], body[2]]) as usize;
                let id = body
                    .get(3..3 + id_len)
                    .ok_or_else(|| invalid("The data frame is truncated"))?;
                let id = String::from_utf8(id.to_vec())
                    .map_err(|_| invalid("The session id is not UTF-8"))?;
                Ok(Some(Frame::Data {
                    id,
                    bytes: body[3 + id_len..].to_vec(),
                }))
            }
            _ => Err(invalid("Unknown frame kind")),
        }
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(frame: Frame) {
        let bytes = frame.encode().unwrap();
        assert_eq!(
            Frame::read_from(&mut bytes.as_slice()).unwrap(),
            Some(frame)
        );
    }

    #[test]
    fn frames_round_trip() {
        round_trip(Frame::Control(Message::Hello {
            version: VERSION,
            token: "abc".into(),
        }));
        round_trip(Frame::Control(Message::List));
        round_trip(Frame::Data {
            id: "tab-1".into(),
            bytes: "한글 \x1b[1mbold\x1b[0m\r\n".as_bytes().to_vec(),
        });
        round_trip(Frame::Data {
            id: "t".into(),
            bytes: vec![],
        });
    }

    #[test]
    fn control_messages_are_tagged_json() {
        let bytes = Frame::Control(Message::Kill { id: "a".into() })
            .encode()
            .unwrap();
        assert_eq!(&bytes[4..], b"\0{\"type\":\"kill\",\"id\":\"a\"}");
    }

    #[test]
    fn closed_stream_and_bad_frames() {
        assert_eq!(Frame::read_from(&mut [].as_slice()).unwrap(), None);
        assert!(Frame::read_from(&mut [0u8, 0, 0, 0].as_slice()).is_err());
        assert!(Frame::read_from(&mut [255u8, 255, 255, 255].as_slice()).is_err());
        assert!(Frame::read_from(&mut [2u8, 0, 0, 9, 0].as_slice()).is_err());
        assert!(Frame::read_from(&mut [3u8, 0, 0, 1, 5, 0].as_slice()).is_err());
    }
}
