//! # JSON-RPC 2.0 Transport Framing
//!
//! Encodes and decodes standard framed messages with `Content-Length: <n>\r\n\r\n<payload>`.

use std::io::{self, BufRead, Write};

/// Reads framed JSON-RPC messages from a buffered reader.
pub struct FramedReader<R> {
    reader: R,
}

impl<R: BufRead> FramedReader<R> {
    pub fn new(reader: R) -> Self {
        Self { reader }
    }

    /// Reads the next complete JSON-RPC message payload.
    /// Returns `Ok(None)` on clean EOF.
    pub fn read_message(&mut self) -> io::Result<Option<String>> {
        let mut content_length: Option<usize> = None;

        // 1. Read headers until empty line "\r\n" or "\n"
        loop {
            let mut line = String::new();
            let bytes_read = self.reader.read_line(&mut line)?;
            if bytes_read == 0 {
                // EOF reached
                if content_length.is_none() {
                    return Ok(None);
                } else {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "Unexpected EOF while reading headers",
                    ));
                }
            }

            let trimmed = line.trim();
            if trimmed.is_empty() {
                // End of header section
                break;
            }

            if let Some(rest) = trimmed.strip_prefix("Content-Length:") {
                let len_str = rest.trim();
                let len = len_str.parse::<usize>().map_err(|e| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("Invalid Content-Length '{}': {}", len_str, e),
                    )
                })?;
                content_length = Some(len);
            }
        }

        let len = match content_length {
            Some(l) => l,
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Missing Content-Length header in message",
                ))
            }
        };

        // 2. Read exactly `len` bytes
        let mut buffer = vec![0u8; len];
        self.reader.read_exact(&mut buffer)?;

        let text = String::from_utf8(buffer).map_err(|e| {
            io::Error::new(io::ErrorKind::InvalidData, format!("Invalid UTF-8: {}", e))
        })?;

        Ok(Some(text))
    }
}

/// Writes framed JSON-RPC messages to a writer.
pub struct FramedWriter<W> {
    writer: W,
}

impl<W: Write> FramedWriter<W> {
    pub fn new(writer: W) -> Self {
        Self { writer }
    }

    /// Serializes and writes a payload framed with `Content-Length`.
    pub fn write_message(&mut self, payload: &str) -> io::Result<()> {
        let bytes = payload.as_bytes();
        write!(
            self.writer,
            "Content-Length: {}\r\n\r\n",
            bytes.len()
        )?;
        self.writer.write_all(bytes)?;
        self.writer.flush()?;
        Ok(())
    }

    /// Helper to write serializable JSON directly.
    pub fn write_json<T: serde::Serialize>(&mut self, value: &T) -> io::Result<()> {
        let json = serde_json::to_string(value)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.write_message(&json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_framed_roundtrip() {
        let payload = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;
        let mut out = Vec::new();
        {
            let mut writer = FramedWriter::new(&mut out);
            writer.write_message(payload).unwrap();
        }

        let mut reader = FramedReader::new(Cursor::new(out));
        let msg = reader.read_message().unwrap().expect("should read message");
        assert_eq!(msg, payload);
    }
}
