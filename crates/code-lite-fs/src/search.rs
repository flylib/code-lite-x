use regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchResult {
    pub file_path: String,
    pub line_number: usize,
    pub col_start: usize,
    pub col_end: usize,
    pub line_snippet: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchOptions {
    #[serde(default)]
    pub is_regex: bool,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default)]
    pub whole_word: bool,
    #[serde(default = "default_max_results")]
    pub max_results: usize,
    pub file_extension: Option<String>,
}

fn default_max_results() -> usize {
    500
}

impl Default for SearchOptions {
    fn default() -> Self {
        Self {
            is_regex: false,
            case_sensitive: false,
            whole_word: false,
            max_results: 500,
            file_extension: None,
        }
    }
}

pub struct WorkspaceSearcher {
    root: PathBuf,
}

impl WorkspaceSearcher {
    pub fn new<P: AsRef<Path>>(root: P) -> Self {
        Self {
            root: root.as_ref().to_path_buf(),
        }
    }

    /// Recursively searches for matches within workspace files.
    pub fn search(
        &self,
        query: &str,
        options: &SearchOptions,
    ) -> Result<Vec<SearchResult>, io::Error> {
        if query.is_empty() {
            return Ok(Vec::new());
        }

        let pattern = if options.is_regex {
            if options.whole_word {
                format!(r"\b{}\b", query)
            } else {
                query.to_string()
            }
        } else {
            let escaped = regex::escape(query);
            if options.whole_word {
                format!(r"\b{}\b", escaped)
            } else {
                escaped
            }
        };

        let re = RegexBuilder::new(&pattern)
            .case_insensitive(!options.case_sensitive)
            .build()
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e.to_string()))?;

        let mut results = Vec::new();
        let mut files = Vec::new();
        self.collect_files(&self.root, options, &mut files)?;

        for file_path in files {
            if results.len() >= options.max_results {
                break;
            }
            let rel_path = file_path
                .strip_prefix(&self.root)
                .unwrap_or(&file_path)
                .to_string_lossy()
                .to_string();

            self.search_file(&file_path, &rel_path, &re, options.max_results, &mut results)?;
        }

        Ok(results)
    }

    /// Replaces occurrences of `query` with `replacement` in files matching options.
    pub fn replace_all(
        &self,
        query: &str,
        replacement: &str,
        options: &SearchOptions,
    ) -> Result<usize, io::Error> {
        let matches = self.search(query, options)?;
        if matches.is_empty() {
            return Ok(0);
        }

        let pattern = if options.is_regex {
            if options.whole_word {
                format!(r"\b{}\b", query)
            } else {
                query.to_string()
            }
        } else {
            let escaped = regex::escape(query);
            if options.whole_word {
                format!(r"\b{}\b", escaped)
            } else {
                escaped
            }
        };

        let re = RegexBuilder::new(&pattern)
            .case_insensitive(!options.case_sensitive)
            .build()
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e.to_string()))?;

        let mut replaced_count = 0;
        let mut affected_files = std::collections::HashSet::new();
        for m in &matches {
            affected_files.insert(m.file_path.clone());
        }

        for rel in affected_files {
            let full_path = self.root.join(&rel);
            let content = fs::read_to_string(&full_path)?;
            let new_content = re.replace_all(&content, replacement);
            if new_content != content {
                fs::write(&full_path, new_content.as_ref())?;
                replaced_count += matches.iter().filter(|m| m.file_path == rel).count();
            }
        }

        Ok(replaced_count)
    }

    fn collect_files(
        &self,
        dir: &Path,
        options: &SearchOptions,
        out: &mut Vec<PathBuf>,
    ) -> io::Result<()> {
        if !dir.is_dir() {
            return Ok(());
        }

        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();

            // Ignore hidden and transient directories
            if name.starts_with('.')
                || name == "target"
                || name == "node_modules"
                || name == "build"
                || name == ".dart_tool"
            {
                continue;
            }

            if path.is_dir() {
                self.collect_files(&path, options, out)?;
            } else if path.is_file() {
                if let Some(ref ext) = options.file_extension {
                    if path.extension().map_or(false, |e| e == ext.as_str()) {
                        out.push(path);
                    }
                } else {
                    out.push(path);
                }
            }
        }

        Ok(())
    }

    fn search_file(
        &self,
        full_path: &Path,
        rel_path: &str,
        re: &regex::Regex,
        max_results: usize,
        results: &mut Vec<SearchResult>,
    ) -> io::Result<()> {
        let file = match fs::File::open(full_path) {
            Ok(f) => f,
            Err(_) => return Ok(()),
        };

        // Skip binary files (check first chunk)
        let mut reader = BufReader::new(file);
        let mut buffer = [0u8; 512];
        let bytes_read = reader.get_mut().read(&mut buffer).unwrap_or(0);
        if buffer[..bytes_read].contains(&0) {
            return Ok(());
        }

        // Rewind
        use std::io::Seek;
        let _ = reader.seek(io::SeekFrom::Start(0));

        for (idx, line_res) in reader.lines().enumerate() {
            if results.len() >= max_results {
                break;
            }
            let line = match line_res {
                Ok(l) => l,
                Err(_) => continue,
            };

            for mat in re.find_iter(&line) {
                if results.len() >= max_results {
                    break;
                }
                results.push(SearchResult {
                    file_path: rel_path.to_string(),
                    line_number: idx + 1,
                    col_start: mat.start(),
                    col_end: mat.end(),
                    line_snippet: line.trim().to_string(),
                });
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn test_workspace_search_and_replace() {
        let temp_dir = std::env::temp_dir().join(format!(
            "search_test_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(temp_dir.join("src")).unwrap();

        fs::write(
            temp_dir.join("src/lib.rs"),
            "pub fn calculate_price(qty: i32) -> i32 { qty * 10 }\n",
        )
        .unwrap();

        fs::write(
            temp_dir.join("README.md"),
            "# Price Service\nCalculate price accurately.\n",
        )
        .unwrap();

        let searcher = WorkspaceSearcher::new(&temp_dir);

        // 1. Search whole word case-insensitive
        let opts = SearchOptions {
            is_regex: false,
            case_sensitive: false,
            whole_word: true,
            max_results: 50,
            file_extension: None,
        };
        let res = searcher.search("calculate", &opts).unwrap();
        assert_eq!(res.len(), 1); // Only README matches whole word "Calculate" (lib.rs has calculate_price)

        // 2. Partial search
        let opts_partial = SearchOptions {
            is_regex: false,
            case_sensitive: false,
            whole_word: false,
            max_results: 50,
            file_extension: None,
        };
        let res_part = searcher.search("price", &opts_partial).unwrap();
        assert_eq!(res_part.len(), 3); // 1 in lib.rs, 2 in README.md

        // 3. Replace in files
        let replaced = searcher
            .replace_all("price", "amount", &opts_partial)
            .unwrap();
        assert_eq!(replaced, 3);

        let new_lib = fs::read_to_string(temp_dir.join("src/lib.rs")).unwrap();
        assert!(new_lib.contains("calculate_amount"));

        let _ = fs::remove_dir_all(&temp_dir);
    }
}
