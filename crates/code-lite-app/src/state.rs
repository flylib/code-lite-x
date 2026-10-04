use code_lite_core::Editor;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct AppState {
    pub workspace_root: PathBuf,
    pub editors: Mutex<HashMap<String, Editor>>,
}

impl AppState {
    // 守护进程只服务文件树 / 文件读写，不再建任何本地数据库
    pub fn new<P: AsRef<Path>>(workspace_root: P) -> Self {
        Self {
            workspace_root: workspace_root.as_ref().to_path_buf(),
            editors: Mutex::new(HashMap::new()),
        }
    }

    /// Gets or loads an Editor for the specified relative file path.
    pub fn get_or_load_editor(&self, rel_path: &str) -> Result<String, std::io::Error> {
        let mut editors = self.editors.lock();
        if let Some(editor) = editors.get(rel_path) {
            return Ok(editor.text());
        }

        let full_path = self.workspace_root.join(rel_path);
        let content = std::fs::read_to_string(&full_path)?;
        let editor = Editor::from_str(&content);
        editors.insert(rel_path.to_string(), editor);

        Ok(content)
    }
}
