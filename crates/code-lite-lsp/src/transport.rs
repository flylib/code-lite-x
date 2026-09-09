//! # JSON-RPC 2.0 Transport Framing
//!
//! Encodes and decodes standard LSP messages framed with `Content-Length: <n>\r\n\r\n<payload>`.


pub use code_lite_rpc::framing::{FramedReader, FramedWriter};

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_framed_roundtrip() {
        let mut buffer = Vec::new();
        {
            let mut writer = FramedWriter::new(&mut buffer);
            writer.write_message(r#"{"jsonrpc":"2.0","id":1,"method":"test"}"#).unwrap();
            writer.write_message(r#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#).unwrap();
        }

        let mut reader = FramedReader::new(Cursor::new(buffer));
        let msg1 = reader.read_message().unwrap().unwrap();
        assert_eq!(msg1, r#"{"jsonrpc":"2.0","id":1,"method":"test"}"#);

        let msg2 = reader.read_message().unwrap().unwrap();
        assert_eq!(msg2, r#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#);

        let eof = reader.read_message().unwrap();
        assert!(eof.is_none());
    }

    #[test]
    fn test_framed_reader_with_extra_headers() {
        let raw = "Content-Length: 13\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{\"key\":\"val\"}";
        let mut reader = FramedReader::new(Cursor::new(raw));
        let msg = reader.read_message().unwrap().unwrap();
        assert_eq!(msg, "{\"key\":\"val\"}");
    }

    #[test]
    fn test_framed_utf8_multi_byte() {
        let payload = r#"{"name":"🦀 Rust 语言"}"#;
        let mut buffer = Vec::new();
        {
            let mut writer = FramedWriter::new(&mut buffer);
            writer.write_message(payload).unwrap();
        }

        let mut reader = FramedReader::new(Cursor::new(buffer));
        let msg = reader.read_message().unwrap().unwrap();
        assert_eq!(msg, payload);
    }
}
