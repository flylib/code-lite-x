use crate::error::AgentError;
use code_lite_storage::{ApprovalRecord, ApprovalStatus, ApprovalStore};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RiskLevel {
    Low,
    Medium,
    Critical,
}

impl RiskLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::Critical => "critical",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "low" => Self::Low,
            "medium" => Self::Medium,
            _ => Self::Critical,
        }
    }
}

/// The Three-Tier Permission Policy evaluator.
#[derive(Clone, Default)]
pub struct PermissionPolicy;

impl PermissionPolicy {
    pub fn new() -> Self {
        Self
    }

    /// Evaluates the risk level of any tool call.
    pub fn evaluate_risk(&self, tool_name: &str, args: &serde_json::Value) -> RiskLevel {
        match tool_name {
            // Tier 1: Low Risk (Read-Only Queries)
            "read_file" | "search_symbol" | "get_code_context" | "lsp_diagnostics" | "git_diff" | "outline" => {
                RiskLevel::Low
            }

            // Tier 2: Medium Risk (Modifications with Snapshot & Rollback)
            "apply_patch" | "rollback_to_step" | "restore_session_start" => RiskLevel::Medium,

            // Tier 3: Critical Risk (Destructive actions)
            "delete_file" => RiskLevel::Critical,

            // Dynamic evaluation for Command Execution
            "execute" => {
                let cmd = args.get("cmd").and_then(|v| v.as_str()).unwrap_or("");
                let args_list = args.get("args").and_then(|v| v.as_array());

                // Read-only / inspection commands
                if cmd == "git" {
                    if let Some(sub) = args_list.and_then(|a| a.first()).and_then(|v| v.as_str()) {
                        if sub == "diff" || sub == "status" || sub == "log" {
                            return RiskLevel::Low;
                        }
                    }
                }

                // Safe compilation / test checks
                if cmd == "cargo" {
                    if let Some(sub) = args_list.and_then(|a| a.first()).and_then(|v| v.as_str()) {
                        if sub == "check" || sub == "test" || sub == "clippy" || sub == "build" {
                            return RiskLevel::Medium;
                        }
                    }
                }

                // Potentially destructive or unverified shell execution
                RiskLevel::Critical
            }

            _ => RiskLevel::Critical,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalDecision {
    Granted,
    RequiresApproval { request_id: String },
    Denied { reason: String },
}

/// ApprovalManager orchestrates user authorization for Critical operations.
#[derive(Clone)]
pub struct ApprovalManager {
    approval_store: ApprovalStore,
    policy: PermissionPolicy,
}

impl ApprovalManager {
    pub fn new(approval_store: ApprovalStore) -> Self {
        Self {
            approval_store,
            policy: PermissionPolicy::new(),
        }
    }

    /// Evaluates tool access and determines if execution can proceed immediately
    /// or if it must suspend for user authorization.
    pub fn check_or_request_approval(
        &self,
        session_id: &str,
        task_id: Option<&str>,
        step_id: &str,
        tool_name: &str,
        args: &serde_json::Value,
    ) -> Result<ApprovalDecision, AgentError> {
        let risk = self.policy.evaluate_risk(tool_name, args);

        match risk {
            RiskLevel::Low => Ok(ApprovalDecision::Granted),

            RiskLevel::Medium | RiskLevel::Critical => {
                // Check if an existing approval request exists for this step
                let existing = self
                    .approval_store
                    .get_pending_approvals(Some(session_id))?
                    .into_iter()
                    .find(|r| r.step_id == step_id);

                if let Some(req) = existing {
                    match req.status {
                        ApprovalStatus::Pending => {
                            Ok(ApprovalDecision::RequiresApproval { request_id: req.id })
                        }
                        ApprovalStatus::Approved => Ok(ApprovalDecision::Granted),
                        ApprovalStatus::Rejected => Ok(ApprovalDecision::Denied {
                            reason: "User rejected this operation".to_string(),
                        }),
                    }
                } else {
                    // Check if already approved/rejected in past approvals
                    let past = self.approval_store.list_approvals(session_id)?;
                    if let Some(req) = past.into_iter().find(|r| r.step_id == step_id) {
                        return match req.status {
                            ApprovalStatus::Approved => Ok(ApprovalDecision::Granted),
                            ApprovalStatus::Rejected => Ok(ApprovalDecision::Denied {
                                reason: "User rejected this operation".to_string(),
                            }),
                            ApprovalStatus::Pending => {
                                Ok(ApprovalDecision::RequiresApproval { request_id: req.id })
                            }
                        };
                    }

                    // Create new pending approval
                    let now = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    let request_id = format!("appr_{}_{}", step_id, now);

                    let record = ApprovalRecord {
                        id: request_id.clone(),
                        session_id: session_id.to_string(),
                        task_id: task_id.map(|s| s.to_string()),
                        step_id: step_id.to_string(),
                        tool_name: tool_name.to_string(),
                        args_json: args.to_string(),
                        risk_level: risk.as_str().to_string(),
                        status: ApprovalStatus::Pending,
                        requested_at: now,
                        resolved_at: None,
                    };

                    self.approval_store.create_request(&record)?;
                    Ok(ApprovalDecision::RequiresApproval { request_id })
                }
            }
        }
    }

    /// User grants approval for a critical request.
    pub fn approve(&self, request_id: &str) -> Result<bool, AgentError> {
        Ok(self.approval_store.resolve_request(request_id, ApprovalStatus::Approved)?)
    }

    /// User denies approval for a critical request.
    pub fn reject(&self, request_id: &str) -> Result<bool, AgentError> {
        Ok(self.approval_store.resolve_request(request_id, ApprovalStatus::Rejected)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_lite_storage::{Database, SessionStore};

    #[test]
    fn test_risk_level_evaluation() {
        let policy = PermissionPolicy::new();

        // Low risk
        assert_eq!(
            policy.evaluate_risk("read_file", &serde_json::json!({"path": "src/lib.rs"})),
            RiskLevel::Low
        );
        assert_eq!(
            policy.evaluate_risk("search_symbol", &serde_json::json!({"query": "Auth"})),
            RiskLevel::Low
        );
        assert_eq!(
            policy.evaluate_risk("execute", &serde_json::json!({"cmd": "git", "args": ["diff"]})),
            RiskLevel::Low
        );

        // Medium risk
        assert_eq!(
            policy.evaluate_risk("apply_patch", &serde_json::json!({"path": "src/main.rs", "content": "..."})),
            RiskLevel::Medium
        );
        assert_eq!(
            policy.evaluate_risk("execute", &serde_json::json!({"cmd": "cargo", "args": ["check"]})),
            RiskLevel::Medium
        );
        assert_eq!(
            policy.evaluate_risk("rollback_to_step", &serde_json::json!({"target_op_id": 1})),
            RiskLevel::Medium
        );

        // Critical risk
        assert_eq!(
            policy.evaluate_risk("delete_file", &serde_json::json!({"path": "src/old.rs"})),
            RiskLevel::Critical
        );
        assert_eq!(
            policy.evaluate_risk("execute", &serde_json::json!({"cmd": "rm", "args": ["-rf", "target"]})),
            RiskLevel::Critical
        );
        assert_eq!(
            policy.evaluate_risk("unknown_tool", &serde_json::json!({})),
            RiskLevel::Critical
        );
    }

    #[test]
    fn test_approval_manager_suspends_critical_and_approves() {
        let db = Database::open_in_memory().unwrap();
        let session_store = SessionStore::new(db.clone());
        let approval_store = ApprovalStore::new(db.clone());
        let manager = ApprovalManager::new(approval_store);

        session_store.create_session("sess-1", "Test Session").unwrap();

        // 1. Low risk is granted immediately
        let dec1 = manager
            .check_or_request_approval(
                "sess-1",
                None,
                "step_1",
                "read_file",
                &serde_json::json!({"path": "README.md"}),
            )
            .unwrap();
        assert_eq!(dec1, ApprovalDecision::Granted);

        // 2. Critical risk generates a pending approval request
        let dec2 = manager
            .check_or_request_approval(
                "sess-1",
                None,
                "step_2",
                "delete_file",
                &serde_json::json!({"path": "secret.key"}),
            )
            .unwrap();

        let req_id = match dec2 {
            ApprovalDecision::RequiresApproval { request_id } => request_id,
            _ => panic!("Expected RequiresApproval"),
        };

        // 3. Second check while pending still returns RequiresApproval
        let dec2_repeat = manager
            .check_or_request_approval(
                "sess-1",
                None,
                "step_2",
                "delete_file",
                &serde_json::json!({"path": "secret.key"}),
            )
            .unwrap();
        assert_eq!(dec2_repeat, ApprovalDecision::RequiresApproval { request_id: req_id.clone() });

        // 4. User approves request
        let approved = manager.approve(&req_id).unwrap();
        assert!(approved);

        // 5. Check now returns Granted
        let dec2_approved = manager
            .check_or_request_approval(
                "sess-1",
                None,
                "step_2",
                "delete_file",
                &serde_json::json!({"path": "secret.key"}),
            )
            .unwrap();
        assert_eq!(dec2_approved, ApprovalDecision::Granted);
    }

    #[test]
    fn test_approval_manager_suspends_medium_and_rejects() {
        let db = Database::open_in_memory().unwrap();
        let session_store = SessionStore::new(db.clone());
        let approval_store = ApprovalStore::new(db.clone());
        let manager = ApprovalManager::new(approval_store);

        session_store.create_session("sess-2", "Test Session 2").unwrap();

        // Medium risk (apply_patch) generates a pending approval request
        let dec = manager
            .check_or_request_approval(
                "sess-2",
                None,
                "step_m1",
                "apply_patch",
                &serde_json::json!({"path": "src/main.rs", "content": "fn main() {}"}),
            )
            .unwrap();

        let req_id = match dec {
            ApprovalDecision::RequiresApproval { request_id } => request_id,
            _ => panic!("Expected RequiresApproval for Medium risk apply_patch"),
        };

        // User rejects request
        let rejected = manager.reject(&req_id).unwrap();
        assert!(rejected);

        // Next check returns Denied
        let dec_rejected = manager
            .check_or_request_approval(
                "sess-2",
                None,
                "step_m1",
                "apply_patch",
                &serde_json::json!({"path": "src/main.rs", "content": "fn main() {}"}),
            )
            .unwrap();
        match dec_rejected {
            ApprovalDecision::Denied { reason } => {
                assert!(reason.contains("User rejected this operation"));
            }
            _ => panic!("Expected Denied"),
        }
    }
}

