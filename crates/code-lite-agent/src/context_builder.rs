use crate::instructions::ProjectInstructions;
use crate::mcp::McpRegistry;
use crate::skill::SkillManager;
use code_lite_graph::CodeGraph;
use code_lite_lsp::{DiagnosticSeverity, LspClient};
use code_lite_storage::MemoryStore;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContextInsights {
    pub instruction_files: Vec<String>,
    pub active_skills: Vec<String>,
    pub recalled_decisions: usize,
    pub recalled_errors: usize,
    pub has_codegraph: bool,
    pub has_lsp_diagnostics: bool,
}

/// AgentContextBuilder unifies Project Instructions, D4 Skills, SQLite Memory Engine,
/// MCP Tools, CodeGraph semantic topology, and LSP diagnostics into a high-density,
/// token-efficient prompt context for the AI Agent.
#[derive(Clone)]
pub struct AgentContextBuilder {
    graph: Option<Arc<dyn CodeGraph + Send + Sync>>,
    lsp: Option<Arc<LspClient>>,
    instructions: Option<ProjectInstructions>,
    memory_store: Option<MemoryStore>,
    skill_manager: Option<SkillManager>,
    mcp_registry: Option<McpRegistry>,
}

impl AgentContextBuilder {
    pub fn new(
        graph: Option<Arc<dyn CodeGraph + Send + Sync>>,
        lsp: Option<Arc<LspClient>>,
    ) -> Self {
        Self {
            graph,
            lsp,
            instructions: None,
            memory_store: None,
            skill_manager: None,
            mcp_registry: None,
        }
    }

    pub fn with_instructions(mut self, instructions: ProjectInstructions) -> Self {
        self.instructions = Some(instructions);
        self
    }

    pub fn with_memory_store(mut self, memory_store: MemoryStore) -> Self {
        self.memory_store = Some(memory_store);
        self
    }

    pub fn with_skill_manager(mut self, skill_manager: SkillManager) -> Self {
        self.skill_manager = Some(skill_manager);
        self
    }

    pub fn with_mcp_registry(mut self, mcp_registry: McpRegistry) -> Self {
        self.mcp_registry = Some(mcp_registry);
        self
    }

    /// Generates a concise context block for a specific symbol including AST definition,
    /// caller hierarchy, and callees.
    pub fn build_symbol_context(&self, symbol_name_or_key: &str) -> Option<String> {
        let graph = self.graph.as_ref()?;
        let ctx = graph.get_code_context(symbol_name_or_key).ok()??;

        let mut output = String::new();
        output.push_str(&format!("### Symbol: {} ({})\n", ctx.name, ctx.kind));
        output.push_str(&format!("File: {}:{}-{}\n", ctx.file_path, ctx.line_start, ctx.line_end));
        if let Some(sig) = &ctx.signature {
            output.push_str(&format!("Signature: `{}`\n", sig));
        }

        output.push_str("\n#### Definition Slice:\n```rust\n");
        output.push_str(&ctx.definition_code);
        output.push_str("\n```\n");

        if !ctx.callers.is_empty() {
            output.push_str("\n#### Callers (Upstream Dependents):\n");
            for c in &ctx.callers {
                output.push_str(&format!("- `{}`\n", c));
            }
        }

        if !ctx.callees.is_empty() {
            output.push_str("\n#### Callees (Downstream Invocations):\n");
            for c in &ctx.callees {
                output.push_str(&format!("- `{}`\n", c));
            }
        }

        if !ctx.references.is_empty() {
            output.push_str("\n#### References Count: ");
            output.push_str(&format!("{}\n", ctx.references.len()));
        }

        Some(output)
    }

    /// Extracts active compilation errors and warnings for a file via LSP.
    pub fn build_file_diagnostics(&self, file_uri_or_path: &str) -> Vec<String> {
        let lsp = match &self.lsp {
            Some(client) => client,
            None => return Vec::new(),
        };

        let uri = if file_uri_or_path.starts_with("file://") {
            file_uri_or_path.to_string()
        } else {
            format!("file://{}", file_uri_or_path)
        };

        let diags = lsp.get_diagnostics(&uri);
        diags
            .into_iter()
            .map(|d| {
                let sev = match d.severity {
                    Some(DiagnosticSeverity::Error) => "[ERROR]",
                    Some(DiagnosticSeverity::Warning) => "[WARN]",
                    Some(DiagnosticSeverity::Information) => "[INFO]",
                    Some(DiagnosticSeverity::Hint) => "[HINT]",
                    None => "[DIAG]",
                };
                format!(
                    "{} L{}:{}: {}",
                    sev,
                    d.range.start.line + 1,
                    d.range.start.character + 1,
                    d.message
                )
            })
            .collect()
    }

    /// Retrieves relevant memory context (Decision Memories & Error Memories)
    pub fn build_memory_context(&self, query: &str, focus_file: Option<&str>) -> Option<String> {
        let store = self.memory_store.as_ref()?;

        let mut decisions = store.query_decisions(query, 3).unwrap_or_default();
        if decisions.is_empty() {
            if let Some(f) = focus_file {
                decisions = store.query_decisions(f, 3).unwrap_or_default();
            }
        }
        let errors = store.query_errors(query, focus_file, 3).unwrap_or_default();

        if decisions.is_empty() && errors.is_empty() {
            return None;
        }

        let mut output = String::from("### Historical Project Memory & Lessons Learned:\n");

        if !decisions.is_empty() {
            output.push_str("#### Relevant Past Decisions & Approvals:\n");
            for d in &decisions {
                output.push_str(&format!(
                    "- [{}] `{}`: {}\n",
                    d.decision_type, d.subject, d.detail
                ));
            }
        }

        if !errors.is_empty() {
            output.push_str("\n#### Past Failure Lessons (\"此路不通\" / Error Memory):\n");
            for e in &errors {
                let target = e.target_path.as_deref().unwrap_or("general");
                output.push_str(&format!(
                    "- [{}] on `{}`: {}\n  *Lesson*: {}\n",
                    e.error_type, target, e.error_summary, e.lesson_learned
                ));
            }
        }

        Some(output.trim_end().to_string())
    }

    /// Builds a full context prompt injecting symbol knowledge and current diagnostics.
    pub fn build_prompt_context(
        &self,
        focus_file: Option<&str>,
        focus_symbol: Option<&str>,
    ) -> String {
        self.build_task_context("", focus_file, focus_symbol)
    }

    /// Unified Phase 10 Context Engine:
    /// Ingests project instructions, matched skills, historical memories, external MCP tools,
    /// symbol hierarchy, and LSP diagnostics into a comprehensive, structured prompt.
    pub fn build_task_context(
        &self,
        task_prompt: &str,
        focus_file: Option<&str>,
        focus_symbol: Option<&str>,
    ) -> String {
        let mut sections = Vec::new();

        // 1. Project-level instruction files (AGENTS.md, GEMINI.md, etc.)
        if let Some(instructions) = &self.instructions {
            if let Some(inst_sec) = instructions.format_for_prompt(2500) {
                sections.push(inst_sec);
            }
        }

        // 2. Specialized Skills (D4 Prompt-first)
        if let Some(skill_manager) = &self.skill_manager {
            let matched = skill_manager.match_skills(task_prompt, 2);
            if let Some(skill_sec) = skill_manager.format_for_prompt(&matched) {
                sections.push(skill_sec);
            }
        }

        // 3. Historical Memory (Decision & Error memory retrieval)
        if !task_prompt.is_empty() || focus_file.is_some() {
            if let Some(mem_sec) = self.build_memory_context(task_prompt, focus_file) {
                sections.push(mem_sec);
            }
        }

        // 4. External MCP Tools
        if let Some(mcp) = &self.mcp_registry {
            if let Some(mcp_sec) = mcp.format_for_prompt() {
                sections.push(mcp_sec);
            }
        }

        // 5. CodeGraph Symbol Topology
        if let Some(sym) = focus_symbol {
            if let Some(sym_ctx) = self.build_symbol_context(sym) {
                sections.push(sym_ctx);
            }
        }

        // 6. Active LSP Diagnostics
        if let Some(file) = focus_file {
            let diags = self.build_file_diagnostics(file);
            if !diags.is_empty() {
                let mut d_sec = format!("### Active LSP Diagnostics for `{}`:\n", file);
                for d in diags {
                    d_sec.push_str(&format!("- {}\n", d));
                }
                sections.push(d_sec);
            }
        }

        if sections.is_empty() {
            "No specific code context loaded.".to_string()
        } else {
            sections.join("\n---\n")
        }
    }

    /// Provides lightweight metadata insights for UI badges and accordions.
    pub fn get_insights(
        &self,
        task_prompt: &str,
        focus_file: Option<&str>,
        focus_symbol: Option<&str>,
    ) -> ContextInsights {
        let instruction_files = self
            .instructions
            .as_ref()
            .map(|i| i.files.iter().map(|f| f.file_name.clone()).collect())
            .unwrap_or_default();

        let active_skills = self
            .skill_manager
            .as_ref()
            .map(|m| {
                m.match_skills(task_prompt, 3)
                    .into_iter()
                    .map(|s| s.name.clone())
                    .collect()
            })
            .unwrap_or_default();

        let (recalled_decisions, recalled_errors) = if let Some(store) = &self.memory_store {
            let mut d_count = store.query_decisions(task_prompt, 10).map(|v| v.len()).unwrap_or(0);
            if d_count == 0 {
                if let Some(f) = focus_file {
                    d_count = store.query_decisions(f, 10).map(|v| v.len()).unwrap_or(0);
                }
            }
            let e_count = store.query_errors(task_prompt, focus_file, 10).map(|v| v.len()).unwrap_or(0);
            (d_count, e_count)
        } else {
            (0, 0)
        };

        let has_codegraph = focus_symbol
            .and_then(|sym| self.build_symbol_context(sym))
            .is_some();

        let has_lsp_diagnostics = focus_file
            .map(|f| !self.build_file_diagnostics(f).is_empty())
            .unwrap_or(false);

        ContextInsights {
            instruction_files,
            active_skills,
            recalled_decisions,
            recalled_errors,
            has_codegraph,
            has_lsp_diagnostics,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instructions::DiscoveredInstruction;
    use crate::skill::Skill;
    use code_lite_storage::{Database, NewDecisionMemory, NewErrorMemory};
    use std::path::PathBuf;

    #[test]
    fn test_unified_context_synthesis() {
        let db = Database::open_in_memory().unwrap();
        let memory_store = MemoryStore::new(db);

        // Pre-populate memories
        memory_store
            .record_decision(&NewDecisionMemory {
                session_id: Some("s1".into()),
                decision_type: "approval_rejected".into(),
                subject: "apply_patch".into(),
                detail: "Do not delete public APIs without deprecation warning".into(),
                context_tags: Some("patch,security".into()),
            })
            .unwrap();

        memory_store
            .record_error(&NewErrorMemory {
                session_id: Some("s1".into()),
                error_type: "rollback".into(),
                target_path: Some("crates/code-lite-agent/src/planner.rs".into()),
                error_summary: "Syntax error on duplicate arm".into(),
                lesson_learned: "Check arms uniqueness before applying patch".into(),
                context_snippet: None,
            })
            .unwrap();

        // Prepare instructions
        let instructions = ProjectInstructions {
            files: vec![DiscoveredInstruction {
                file_name: "AGENTS.md".into(),
                path: PathBuf::from("AGENTS.md"),
                content: "# AGENTS Rules\n1. Offline cargo\n2. Three-tier security".into(),
                char_count: 50,
            }],
        };

        // Prepare skills
        let skill = Skill {
            name: "flutter-ui".into(),
            description: "Darcula dark theme and defensive layout".into(),
            tools: vec!["read_file".into()],
            instructions: "Wrap with Expanded.".into(),
            file_path: PathBuf::from("s.md"),
        };
        let skill_manager = SkillManager::with_skills(vec![skill]);

        // Prepare MCP registry
        let mut mcp_registry = McpRegistry::new();
        mcp_registry.register(
            "codegraph_search",
            "codegraph",
            "Search symbols across graph",
            serde_json::json!({}),
        );

        let builder = AgentContextBuilder::new(None, None)
            .with_instructions(instructions)
            .with_memory_store(memory_store)
            .with_skill_manager(skill_manager)
            .with_mcp_registry(mcp_registry);

        let task_prompt = "Fix flutter layout in planner";
        let context = builder.build_task_context(task_prompt, Some("crates/code-lite-agent/src/planner.rs"), None);

        // Assert all dimensions are integrated
        assert!(context.contains("### Project-Level Architecture & Development Rules:"));
        assert!(context.contains("AGENTS.md"));
        assert!(context.contains("### Active Specialized Skills (D4 Prompt-First):"));
        assert!(context.contains("flutter-ui"));
        assert!(context.contains("### Historical Project Memory & Lessons Learned:"));
        assert!(context.contains("Syntax error on duplicate arm"));
        assert!(context.contains("### Available External MCP Tools"));
        assert!(context.contains("codegraph_search"));

        // Assert insights
        let insights = builder.get_insights(task_prompt, Some("crates/code-lite-agent/src/planner.rs"), None);
        assert_eq!(insights.instruction_files, vec!["AGENTS.md"]);
        assert_eq!(insights.active_skills, vec!["flutter-ui"]);
        assert!(insights.recalled_errors >= 1);
    }
}
