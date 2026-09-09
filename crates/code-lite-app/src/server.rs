use crate::frontend::INDEX_HTML;
use crate::state::AppState;
use std::sync::Arc;
use tiny_http::{Header, Response, Server};

pub fn run_server(state: Arc<AppState>, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("127.0.0.1:{}", port);
    let server = Server::http(&addr).map_err(|e| format!("Failed to bind to {}: {}", addr, e))?;
    println!("CodeLiteX IntelliJ-style UI Server running at http://{}", addr);

    for request in server.incoming_requests() {
        let url = request.url().to_string();
        let method = request.method().as_str();

        // 1. Static Root UI
        if url == "/" || url == "/index.html" {
            let mut res = Response::from_string(INDEX_HTML);
            res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"text/html; charset=utf-8"[..]).unwrap());
            let _ = request.respond(res);
            continue;
        }

        // 2. /api/workspace
        if url == "/api/workspace" {
            let tree = code_lite_fs::WorkspaceTree::new(&state.workspace_root);
            let entry = tree.scan(5).unwrap_or_else(|_| code_lite_fs::FileSystemEntry::new_dir(state.workspace_root.clone(), vec![]));
            let json = serde_json::to_string(&entry).unwrap_or_default();
            let mut res = Response::from_string(json);
            res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap());
            let _ = request.respond(res);
            continue;
        }

        // 3. /api/file?path=...
        if url.starts_with("/api/file") {
            let query = url.split('?').nth(1).unwrap_or("");
            let rel_path = query
                .split('&')
                .find(|part| part.starts_with("path="))
                .and_then(|p| p.strip_prefix("path="))
                .map(|p| urlencoding::decode(p).unwrap_or_else(|_| p.to_string().into()))
                .unwrap_or_default();

            match state.get_or_load_editor(&rel_path) {
                Ok(content) => {
                    let body = serde_json::json!({
                        "path": rel_path,
                        "content": content,
                        "lines": content.lines().count()
                    });
                    let mut res = Response::from_string(body.to_string());
                    res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap());
                    let _ = request.respond(res);
                }
                Err(e) => {
                    let res = Response::from_string(format!("{{\"error\": \"{}\"}}", e)).with_status_code(404);
                    let _ = request.respond(res);
                }
            }
            continue;
        }

        // 4. /api/undo
        if url == "/api/undo" && method == "POST" {
            let mut req = request;
            let mut body_str = String::new();
            let _ = req.as_reader().read_to_string(&mut body_str);
            let payload: serde_json::Value = serde_json::from_str(&body_str).unwrap_or_default();
            let path = payload["path"].as_str().unwrap_or("");

            let mut editors = state.editors.lock();
            if let Some(editor) = editors.get_mut(path) {
                editor.undo();
                let res_json = serde_json::json!({
                    "path": path,
                    "content": editor.text(),
                    "can_undo": editor.can_undo(),
                    "can_redo": editor.can_redo(),
                });
                let mut res = Response::from_string(res_json.to_string());
                res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap());
                let _ = req.respond(res);
            } else {
                let _ = req.respond(Response::from_string("{\"error\": \"not found\"}").with_status_code(404));
            }
            continue;
        }

        // 5. /api/redo
        if url == "/api/redo" && method == "POST" {
            let mut req = request;
            let mut body_str = String::new();
            let _ = req.as_reader().read_to_string(&mut body_str);
            let payload: serde_json::Value = serde_json::from_str(&body_str).unwrap_or_default();
            let path = payload["path"].as_str().unwrap_or("");

            let mut editors = state.editors.lock();
            if let Some(editor) = editors.get_mut(path) {
                editor.redo();
                let res_json = serde_json::json!({
                    "path": path,
                    "content": editor.text(),
                    "can_undo": editor.can_undo(),
                    "can_redo": editor.can_redo(),
                });
                let mut res = Response::from_string(res_json.to_string());
                res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap());
                let _ = req.respond(res);
            } else {
                let _ = req.respond(Response::from_string("{\"error\": \"not found\"}").with_status_code(404));
            }
            continue;
        }

        // 6. /api/storage/events
        if url == "/api/storage/events" {
            let events = state.event_store.list(None, 30).unwrap_or_default();
            let json = serde_json::to_string(&events).unwrap_or_default();
            let mut res = Response::from_string(json);
            res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap());
            let _ = request.respond(res);
            continue;
        }

        // 6b. /api/storage/operations
        if url == "/api/storage/operations" {
            // Retrieve recent tasks / operations
            let sessions = state.session_store.list_sessions().unwrap_or_default();
            let json = serde_json::to_string(&sessions).unwrap_or_default();
            let mut res = Response::from_string(json);
            res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap());
            let _ = request.respond(res);
            continue;
        }

        // 6c. /api/storage/revert
        if url == "/api/storage/revert" && method == "POST" {
            let mut req = request;
            let mut body_str = String::new();
            let _ = req.as_reader().read_to_string(&mut body_str);
            let payload: serde_json::Value = serde_json::from_str(&body_str).unwrap_or_default();
            if let Some(op_id) = payload["op_id"].as_i64() {
                let _ = state.op_store.revert(op_id);
            } else if let Some(task_id) = payload["task_id"].as_str() {
                let _ = state.op_store.revert_task(task_id);
            }
            let res = Response::from_string("{\"success\": true}");
            let _ = req.respond(res);
            continue;
        }

        // 7. /api/graph/symbols
        if url.starts_with("/api/graph/symbols") {
            let query = url.split('?').nth(1).unwrap_or("");
            let q = query
                .split('&')
                .find(|part| part.starts_with("query="))
                .and_then(|p| p.strip_prefix("query="))
                .unwrap_or("");

            let symbols = state.graph_store.find_symbols_by_name(q).unwrap_or_default();
            let json = serde_json::to_string(&symbols).unwrap_or_default();
            let mut res = Response::from_string(json);
            res.add_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap());
            let _ = request.respond(res);
            continue;
        }

        // Fallback 404
        let _ = request.respond(Response::from_string("Not Found").with_status_code(404));
    }

    Ok(())
}

mod urlencoding {
    pub fn decode(s: &str) -> Result<String, std::string::FromUtf8Error> {
        let mut bytes = Vec::new();
        let mut chars = s.bytes();
        while let Some(b) = chars.next() {
            if b == b'%' {
                let h1 = chars.next().unwrap_or(0);
                let h2 = chars.next().unwrap_or(0);
                if let Ok(num) = u8::from_str_radix(std::str::from_utf8(&[h1, h2]).unwrap_or("00"), 16) {
                    bytes.push(num);
                }
            } else if b == b'+' {
                bytes.push(b' ');
            } else {
                bytes.push(b);
            }
        }
        String::from_utf8(bytes)
    }
}
