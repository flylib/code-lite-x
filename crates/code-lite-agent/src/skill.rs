use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SkillFrontmatter {
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub tools: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub tools: Vec<String>,
    pub instructions: String,
    pub file_path: PathBuf,
}

#[derive(Debug, Clone, Default)]
pub struct SkillManager {
    skills: Vec<Skill>,
}

impl SkillManager {
    pub fn new() -> Self {
        Self { skills: Vec::new() }
    }

    pub fn with_skills(skills: Vec<Skill>) -> Self {
        Self { skills }
    }

    pub fn skills(&self) -> &[Skill] {
        &self.skills
    }

    /// Parses a single `SKILL.md` content string into a `Skill`.
    /// The file must have YAML frontmatter between `---` delimiters.
    pub fn parse_skill_markdown(content: &str, file_path: PathBuf) -> Result<Skill, String> {
        let trimmed = content.trim();
        if !trimmed.starts_with("---") {
            return Err("Missing opening `---` YAML frontmatter delimiter".into());
        }

        let after_first = &trimmed[3..];
        let end_fm = after_first
            .find("\n---")
            .ok_or_else(|| "Missing closing `---` YAML frontmatter delimiter".to_string())?;

        let fm_str = &after_first[..end_fm].trim();
        let body = after_first[end_fm + 4..].trim();

        // Simple YAML parser for `name`, `description`, and `tools`
        let frontmatter = Self::parse_simple_yaml(fm_str)?;

        Ok(Skill {
            name: frontmatter.name,
            description: frontmatter.description,
            tools: frontmatter.tools,
            instructions: body.to_string(),
            file_path,
        })
    }

    fn parse_simple_yaml(yaml: &str) -> Result<SkillFrontmatter, String> {
        let mut name = String::new();
        let mut description = String::new();
        let mut tools = Vec::new();
        let mut in_tools_list = false;

        for line in yaml.lines() {
            let line_trim = line.trim();
            if line_trim.is_empty() || line_trim.starts_with('#') {
                continue;
            }

            if line_trim.starts_with("name:") {
                in_tools_list = false;
                name = line_trim["name:".len()..].trim().trim_matches('"').trim_matches('\'').to_string();
            } else if line_trim.starts_with("description:") {
                in_tools_list = false;
                description = line_trim["description:".len()..].trim().trim_matches('"').trim_matches('\'').to_string();
            } else if line_trim.starts_with("tools:") {
                let val = line_trim["tools:".len()..].trim();
                if val.starts_with('[') && val.ends_with(']') {
                    in_tools_list = false;
                    let inner = &val[1..val.len() - 1];
                    for item in inner.split(',') {
                        let t = item.trim().trim_matches('"').trim_matches('\'').to_string();
                        if !t.is_empty() {
                            tools.push(t);
                        }
                    }
                } else {
                    in_tools_list = true;
                }
            } else if in_tools_list && line_trim.starts_with('-') {
                let tool = line_trim[1..].trim().trim_matches('"').trim_matches('\'').to_string();
                if !tool.is_empty() {
                    tools.push(tool);
                }
            }
        }

        if name.is_empty() {
            return Err("Skill YAML frontmatter missing `name` field".into());
        }

        Ok(SkillFrontmatter {
            name,
            description,
            tools,
        })
    }

    /// Validates the hard safety boundary:
    /// All tools bound by the Skill MUST exist in the authorized set.
    pub fn validate_authorized_tools(&self, authorized_tools: &HashSet<String>) -> Vec<String> {
        let mut violations = Vec::new();
        for skill in &self.skills {
            for tool in &skill.tools {
                if !authorized_tools.contains(tool) {
                    violations.push(format!(
                        "Skill `{}` illegally attempts to bind unauthorized or non-existent tool `{}`",
                        skill.name, tool
                    ));
                }
            }
        }
        violations
    }

    /// Scans workspace directories (`.codelite/skills/` and `skills/`) for `SKILL.md` files.
    pub fn scan_workspace(workspace_root: &Path) -> Self {
        let mut discovered = Vec::new();
        let search_roots = [
            workspace_root.join(".codelite").join("skills"),
            workspace_root.join("skills"),
        ];

        for dir in &search_roots {
            if dir.is_dir() {
                Self::collect_skills_from_dir(dir, &mut discovered);
            }
        }

        Self { skills: discovered }
    }

    fn collect_skills_from_dir(dir: &Path, list: &mut Vec<Skill>) {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    Self::collect_skills_from_dir(&path, list);
                } else if path.is_file() {
                    let filename = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                    if filename.eq_ignore_ascii_case("SKILL.md") || filename.ends_with(".skill.md") {
                        if let Ok(content) = std::fs::read_to_string(&path) {
                            if let Ok(skill) = Self::parse_skill_markdown(&content, path) {
                                list.push(skill);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Matches and scores skills relevant to a user task/prompt using description & tag keyword overlap.
    pub fn match_skills(&self, task_prompt: &str, limit: usize) -> Vec<&Skill> {
        if self.skills.is_empty() {
            return Vec::new();
        }

        let prompt_lower = task_prompt.to_lowercase();
        let prompt_tokens: HashSet<&str> = prompt_lower
            .split(|c: char| !c.is_alphanumeric() && c != '-' && c != '_')
            .filter(|s| s.len() >= 2)
            .collect();

        let mut scored: Vec<(usize, &Skill)> = self
            .skills
            .iter()
            .filter_map(|skill| {
                let mut score = 0;
                let name_lower = skill.name.to_lowercase();
                let desc_lower = skill.description.to_lowercase();

                // Check exact name inclusion
                if prompt_lower.contains(&name_lower) {
                    score += 10;
                }

                // Token matching on description and name
                for token in &prompt_tokens {
                    if name_lower.contains(token) {
                        score += 3;
                    }
                    if desc_lower.contains(token) {
                        score += 1;
                    }
                }

                if score > 0 {
                    Some((score, skill))
                } else {
                    None
                }
            })
            .collect();

        scored.sort_by(|a, b| b.0.cmp(&a.0));
        scored.into_iter().take(limit).map(|(_, skill)| skill).collect()
    }

    /// Formats matched skills into a high-density markdown context prompt block.
    pub fn format_for_prompt(&self, matched: &[&Skill]) -> Option<String> {
        if matched.is_empty() {
            return None;
        }

        let mut output = String::from("### Active Specialized Skills (D4 Prompt-First):\n");
        for skill in matched {
            output.push_str(&format!("#### Skill: `{}`\n", skill.name));
            if !skill.description.is_empty() {
                output.push_str(&format!("*Description*: {}\n", skill.description));
            }
            if !skill.tools.is_empty() {
                output.push_str(&format!("*Permitted Tools*: [{}]\n", skill.tools.join(", ")));
            }
            output.push_str("\n*Instructions*:\n");
            output.push_str(&skill.instructions);
            output.push_str("\n\n");
        }

        Some(output.trim_end().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_skill_frontmatter_and_validation() {
        let content = r#"---
name: flutter-ui
description: IntelliJ Darcula UI guidelines, defensive Row wrapping and InkWell touch target constraints
tools: [read_file, apply_patch]
---
# Flutter UI Skill
1. Use IntelliJTheme.
2. Always wrap Row text with Expanded/Flexible.
"#;

        let skill = SkillManager::parse_skill_markdown(content, PathBuf::from("test/SKILL.md")).unwrap();
        assert_eq!(skill.name, "flutter-ui");
        assert_eq!(skill.tools, vec!["read_file", "apply_patch"]);
        assert!(skill.instructions.contains("Always wrap Row text with Expanded/Flexible"));

        let mut authorized = HashSet::new();
        authorized.insert("read_file".to_string());
        authorized.insert("apply_patch".to_string());

        let manager = SkillManager::with_skills(vec![skill.clone()]);
        let violations = manager.validate_authorized_tools(&authorized);
        assert!(violations.is_empty());

        // Violate safety boundary with unauthorized tool
        let unauthorized_skill = Skill {
            name: "docker-escape".into(),
            description: "Install external binaries".into(),
            tools: vec!["unauthorized_plugin_exec".into()],
            instructions: "Run unsafe tool".into(),
            file_path: PathBuf::from("unsafe.md"),
        };
        let unsafe_manager = SkillManager::with_skills(vec![unauthorized_skill]);
        let violations = unsafe_manager.validate_authorized_tools(&authorized);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("illegally attempts to bind unauthorized"));
    }

    #[test]
    fn test_skill_matching_and_formatting() {
        let skill1 = Skill {
            name: "flutter-ui".into(),
            description: "Defensive Row layout and Darcula dark theme guidelines".into(),
            tools: vec!["apply_patch".into()],
            instructions: "Wrap with Expanded to avoid RenderFlex overflows.".into(),
            file_path: PathBuf::from("s1.md"),
        };
        let skill2 = Skill {
            name: "sql-optimizer".into(),
            description: "Postgres and SQLite query tuning and index strategies".into(),
            tools: vec!["read_file".into()],
            instructions: "Use EXPLAIN QUERY PLAN and composite indexes.".into(),
            file_path: PathBuf::from("s2.md"),
        };

        let manager = SkillManager::with_skills(vec![skill1, skill2]);

        // Prompt mentions flutter layout
        let matched = manager.match_skills("Please fix the flutter renderflex overflow issue", 2);
        assert_eq!(matched.len(), 1);
        assert_eq!(matched[0].name, "flutter-ui");

        let prompt = manager.format_for_prompt(&matched).unwrap();
        assert!(prompt.contains("### Active Specialized Skills (D4 Prompt-First):"));
        assert!(prompt.contains("#### Skill: `flutter-ui`"));
        assert!(prompt.contains("Wrap with Expanded to avoid RenderFlex overflows."));
    }
}
