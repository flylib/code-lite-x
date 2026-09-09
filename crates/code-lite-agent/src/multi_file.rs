use crate::planner::{Plan, TaskPlanner};
use code_lite_graph::engine::CodeGraph;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilePatchTarget {
    pub file_path: String,
    pub patch: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MultiFilePlanSummary {
    pub task_id: String,
    pub sorted_files: Vec<String>,
    pub patches: Vec<FilePatchTarget>,
}

pub struct MultiFilePlanner {
    planner: TaskPlanner,
}

impl Default for MultiFilePlanner {
    fn default() -> Self {
        Self::new()
    }
}

impl MultiFilePlanner {
    pub fn new() -> Self {
        Self {
            planner: TaskPlanner::new(),
        }
    }

    /// Sorts files using Kahn's topological sort algorithm such that upstream/depended-on files
    /// (e.g. models / interfaces) come before downstream dependents (e.g. services / handlers).
    pub fn sort_files_by_dependencies<G: CodeGraph + ?Sized>(
        &self,
        files: &[String],
        graph: &G,
    ) -> Vec<String> {
        let file_set: HashSet<String> = files.iter().cloned().collect();
        if file_set.len() <= 1 {
            return files.to_vec();
        }

        // in_degree: number of prerequisites a file has
        let mut in_degree: HashMap<String, usize> = HashMap::new();
        // adj: file -> list of files that depend on it (file must be processed before them)
        let mut adj: HashMap<String, Vec<String>> = HashMap::new();

        for f in &file_set {
            in_degree.insert(f.clone(), 0);
            adj.insert(f.clone(), Vec::new());
        }

        // Query graph for references / callers
        for f in &file_set {
            if let Ok(refs) = graph.find_references(f) {
                for r in refs {
                    if file_set.contains(&r.file_path) && &r.file_path != f {
                        // r.file_path references f, so f must come BEFORE r.file_path
                        let neighbors = adj.get_mut(f).unwrap();
                        if !neighbors.contains(&r.file_path) {
                            neighbors.push(r.file_path.clone());
                            *in_degree.get_mut(&r.file_path).unwrap() += 1;
                        }
                    }
                }
            }
        }

        // Kahn's algorithm with deterministic tie-breaking (alphabetical)
        let mut queue: VecDeque<String> = VecDeque::new();
        let mut zero_in: Vec<String> = in_degree
            .iter()
            .filter(|(_, &deg)| deg == 0)
            .map(|(k, _)| k.clone())
            .collect();
        zero_in.sort();
        for node in zero_in {
            queue.push_back(node);
        }

        let mut sorted = Vec::new();
        while let Some(u) = queue.pop_front() {
            sorted.push(u.clone());
            if let Some(neighbors) = adj.get(&u) {
                let mut next_nodes = Vec::new();
                for v in neighbors {
                    let deg = in_degree.get_mut(v).unwrap();
                    *deg -= 1;
                    if *deg == 0 {
                        next_nodes.push(v.clone());
                    }
                }
                next_nodes.sort();
                for node in next_nodes {
                    queue.push_back(node);
                }
            }
        }

        // If there were cycles, append any remaining files in stable alphabetical order
        if sorted.len() < files.len() {
            let visited: HashSet<String> = sorted.iter().cloned().collect();
            let mut remaining: Vec<String> = files
                .iter()
                .filter(|f| !visited.contains(*f))
                .cloned()
                .collect();
            remaining.sort();
            sorted.extend(remaining);
        }

        sorted
    }

    /// Formulates a multi-file plan ordered by dependency topology.
    pub fn plan_multi_file_task<G: CodeGraph + ?Sized>(
        &self,
        session_id: &str,
        task_id: &str,
        prompt: &str,
        patches: Vec<FilePatchTarget>,
        graph: &G,
    ) -> (Plan, MultiFilePlanSummary) {
        let files: Vec<String> = patches.iter().map(|p| p.file_path.clone()).collect();
        let sorted_files = self.sort_files_by_dependencies(&files, graph);

        let patch_map: HashMap<String, FilePatchTarget> = patches
            .into_iter()
            .map(|p| (p.file_path.clone(), p))
            .collect();

        let mut steps = Vec::new();
        let mut ordered_patches = Vec::new();

        for (idx, file) in sorted_files.iter().enumerate() {
            if let Some(target) = patch_map.get(file) {
                ordered_patches.push(target.clone());

                // 1. Inspect file
                steps.push(self.planner.create_step(
                    &format!("step_{}_read", idx + 1),
                    &format!("Read baseline of dependent `{}`", file),
                    "read_file",
                    serde_json::json!({ "path": file }),
                ));

                // 2. Apply patch
                steps.push(self.planner.create_step(
                    &format!("step_{}_patch", idx + 1),
                    &format!("Apply topologically ordered patch to `{}`: {}", file, target.description),
                    "apply_patch",
                    serde_json::json!({ "path": file, "content": target.patch }),
                ));

                // 3. LSP verify
                steps.push(self.planner.create_step(
                    &format!("step_{}_verify", idx + 1),
                    &format!("Verify syntax and references in `{}`", file),
                    "lsp_diagnostics",
                    serde_json::json!({ "path": file }),
                ));
            }
        }

        // Final whole-workspace build verification
        steps.push(self.planner.create_step(
            "step_final_build",
            "Verify entire workspace build and integration consistency",
            "execute",
            serde_json::json!({ "cmd": "cargo", "args": ["check"] }),
        ));

        let summary = MultiFilePlanSummary {
            task_id: task_id.to_string(),
            sorted_files: sorted_files.clone(),
            patches: ordered_patches,
        };

        let plan = Plan::new(session_id, task_id, prompt, steps);
        (plan, summary)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_lite_graph::engine::IndexReport;
    use code_lite_graph::error::GraphError;
    use code_lite_graph::outline::{CodeContext, DefinitionLocation, OutlineNode, ReferenceLocation};
    use code_lite_storage::{ImportRecord, SymbolRecord};

    struct MockGraph {
        references: HashMap<String, Vec<ReferenceLocation>>,
    }

    impl CodeGraph for MockGraph {
        fn index_file(&self, _rel_path: &str, _content: &str) -> Result<IndexReport, GraphError> {
            unimplemented!()
        }
        fn outline(&self, _rel_path: &str, _content: Option<&str>) -> Result<Vec<OutlineNode>, GraphError> {
            unimplemented!()
        }
        fn find_definitions(&self, _query: &str) -> Result<Vec<DefinitionLocation>, GraphError> {
            unimplemented!()
        }
        fn find_references(&self, query: &str) -> Result<Vec<ReferenceLocation>, GraphError> {
            Ok(self.references.get(query).cloned().unwrap_or_default())
        }
        fn find_callers(&self, _key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
            unimplemented!()
        }
        fn find_callees(&self, _key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
            unimplemented!()
        }
        fn find_imports(&self, _file_id: i64) -> Result<Vec<ImportRecord>, GraphError> {
            unimplemented!()
        }
        fn find_symbols_by_name(&self, _name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
            unimplemented!()
        }
        fn get_code_context(&self, _key_or_name: &str) -> Result<Option<CodeContext>, GraphError> {
            unimplemented!()
        }
    }

    #[test]
    fn test_topological_dependency_sorting() {
        let mut refs = HashMap::new();
        // service.rs and handler.rs depend on models.rs
        refs.insert(
            "models.rs".to_string(),
            vec![
                ReferenceLocation {
                    file_path: "service.rs".to_string(),
                    symbol_key: "models::User".to_string(),
                    name: "User".to_string(),
                    line: 5,
                    caller_name: Some("get_user".to_string()),
                },
                ReferenceLocation {
                    file_path: "handler.rs".to_string(),
                    symbol_key: "models::User".to_string(),
                    name: "User".to_string(),
                    line: 8,
                    caller_name: Some("handle_request".to_string()),
                },
            ],
        );
        // handler.rs depends on service.rs
        refs.insert(
            "service.rs".to_string(),
            vec![ReferenceLocation {
                file_path: "handler.rs".to_string(),
                symbol_key: "service::UserService".to_string(),
                name: "UserService".to_string(),
                line: 12,
                caller_name: Some("handle_request".to_string()),
            }],
        );

        let mock_graph = MockGraph { references: refs };
        let planner = MultiFilePlanner::new();

        let input_files = vec![
            "handler.rs".to_string(),
            "models.rs".to_string(),
            "service.rs".to_string(),
        ];

        let sorted = planner.sort_files_by_dependencies(&input_files, &mock_graph);
        // Expected order: models.rs -> service.rs -> handler.rs
        assert_eq!(sorted, vec!["models.rs", "service.rs", "handler.rs"]);
    }
}
