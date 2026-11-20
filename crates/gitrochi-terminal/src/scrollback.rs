use std::collections::VecDeque;

/// The last output of a session, replayed when the app reattaches
pub struct Scrollback {
    bytes: VecDeque<u8>,
    limit: usize,
    trimmed: bool,
}

impl Scrollback {
    pub fn new(limit: usize) -> Self {
        Self {
            bytes: VecDeque::new(),
            limit,
            trimmed: false,
        }
    }

    pub fn push(&mut self, chunk: &[u8]) {
        self.bytes.extend(chunk);
        if self.bytes.len() > self.limit {
            self.bytes.drain(..self.bytes.len() - self.limit);
            self.trimmed = true;
        }
    }

    /// What to replay. Once the oldest output was dropped, it starts after the first line break, so the replay does
    /// not open inside a cut character or escape sequence.
    pub fn snapshot(&self) -> Vec<u8> {
        let (a, b) = self.bytes.as_slices();
        let all = [a, b].concat();
        if !self.trimmed {
            return all;
        }
        match all.iter().position(|&b| b == b'\n') {
            Some(i) => all[i + 1..].to_vec(),
            None => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_everything_under_the_limit() {
        let mut s = Scrollback::new(64);
        s.push(b"one\r\n");
        s.push(b"two");
        assert_eq!(s.snapshot(), b"one\r\ntwo");
    }

    #[test]
    fn drops_the_oldest_and_starts_on_a_whole_line() {
        let mut s = Scrollback::new(10);
        s.push(b"first line\r\nsecond\r\nthird");
        assert_eq!(s.snapshot(), b"third");
        let mut s = Scrollback::new(4);
        s.push(b"abcdefgh");
        assert_eq!(s.snapshot(), b"");
    }
}
