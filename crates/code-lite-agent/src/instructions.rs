use std::path::{Path, PathBuf};

/// Known project instruction files in order of discovery priority.
pub const INSTRUCTION_FILENAMES: &[&str] = &[
    "AGENTS.md",
    "GEMINI.md",
    "CLAUDE.md",
    ".cursorrules",
    ".codelite/instructions.md",
];

#[derive(Debug, Clone)]
pub struct DiscoveredInstruction {
    pub file_name: String,
    pub path: PathBuf,
    pub content: String,
    pub char_count: usize,
}

#[derive(Debug, Clone, Default)]
pub struct ProjectInstructions {
    pub files: Vec<DiscoveredInstruction>,
}

impl ProjectInstructions {
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// Formats all discovered project instructions into a token-efficient markdown context block.
    /// `max_chars_per_file` prevents any single instruction file from dominating the context budget.
    pub fn format_for_prompt(&self, max_chars_per_file: usize) -> Option<String> {
        if self.files.is_empty() {
            return None;
        }

        let mut output = String::from("### Project-Level Architecture & Development Rules:\n");
        for file in &self.files {
            output.push_str(&format!("#### Rules from `{}`:\n", file.file_name));

            let trimmed = file.content.trim();
            if trimmed.chars().count() <= max_chars_per_file {
                output.push_str(trimmed);
            } else {
                let truncated: String = trimmed.chars().take(max_chars_per_file).collect();
                output.push_str(&truncated);
                output.push_str("\n... [Rules truncated for context efficiency] ...");
            }
            output.push_str("\n\n");
        }

        Some(output.trim_end().to_string())
    }
}

pub struct InstructionScanner;

impl InstructionScanner {
    /// Scans the given workspace directory for known project instruction files.
    pub fn scan(workspace_root: &Path) -> ProjectInstructions {
        let mut discovered = Vec::new();

        for &rel_name in INSTRUCTION_FILENAMES {
            let full_path = workspace_root.join(rel_name);
            if full_path.is_file() {
                if let Ok(content) = std::fs::read_to_string(&full_path) {
                    let trimmed = content.trim();
                    if !trimmed.is_empty() {
                        let char_count = trimmed.chars().count();
                        discovered.push(DiscoveredInstruction {
                            file_name: rel_name.to_string(),
                            path: full_path,
                            content: trimmed.to_string(),
                            char_count,
                        });
                    }
                }
            }
        }

        ProjectInstructions { files: discovered }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_instruction_scanner_finds_files_and_truncates() {
        let temp_dir = std::env::temp_dir().join(format!(
            "instr_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::create_dir_all(&temp_dir);
        let root = &temp_dir;

        // 1. Initially empty
        let empty_res = InstructionScanner::scan(root);
        assert!(empty_res.is_empty());
        assert!(empty_res.format_for_prompt(1000).is_none());

        // 2. Create AGENTS.md and .cursorrules
        fs::write(
            root.join("AGENTS.md"),
            "# CodeLiteX Rules\n- Offline cargo build\n- Three-tier permissions\n",
        )
        .unwrap();

        fs::create_dir_all(root.join(".codelite")).unwrap();
        fs::write(
            root.join(".codelite/instructions.md"),
            "# Internal instructions\nAlways run tests before commit.\n",
        )
        .unwrap();

        let scanned = InstructionScanner::scan(root);
        assert_eq!(scanned.files.len(), 2);
        assert_eq!(scanned.files[0].file_name, "AGENTS.md");
        assert_eq!(scanned.files[1].file_name, ".codelite/instructions.md");

        let formatted = scanned.format_for_prompt(2000).unwrap();
        assert!(formatted.contains("### Project-Level Architecture & Development Rules:"));
        assert!(formatted.contains("#### Rules from `AGENTS.md`:"));
        assert!(formatted.contains("Three-tier permissions"));
        assert!(formatted.contains("Always run tests before commit"));

        // 3. Test truncation with small limit
        let truncated = scanned.format_for_prompt(15).unwrap();
        assert!(truncated.contains("... [Rules truncated for context efficiency] ..."));
    }
}
