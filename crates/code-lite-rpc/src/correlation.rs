//! # Request-Response Correlation
//!
//! Correlates outgoing request IDs with incoming responses across threads and transports.

use anyhow::{anyhow, Result};
use parking_lot::{Condvar, Mutex};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

type ResponseSlot = Arc<(Mutex<Option<Result<serde_json::Value>>>, Condvar)>;

#[derive(Debug, Default)]
pub struct RpcTracker {
    next_id: AtomicU64,
    pending: Arc<Mutex<HashMap<u64, ResponseSlot>>>,
}

impl RpcTracker {
    pub fn new() -> Self {
        Self {
            next_id: AtomicU64::new(1),
            pending: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn next_request_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::SeqCst)
    }

    /// Registers a pending request ID to await its response.
    pub fn register(&self, id: u64) -> ResponseSlot {
        let slot = Arc::new((Mutex::new(None), Condvar::new()));
        self.pending.lock().insert(id, slot.clone());
        slot
    }

    /// Fulfills a pending request with a successful result.
    pub fn fulfill(&self, id: u64, result: serde_json::Value) -> bool {
        if let Some(slot) = self.pending.lock().remove(&id) {
            *slot.0.lock() = Some(Ok(result));
            slot.1.notify_all();
            true
        } else {
            false
        }
    }

    /// Rejects a pending request with an error.
    pub fn reject(&self, id: u64, error: impl Into<String>) -> bool {
        if let Some(slot) = self.pending.lock().remove(&id) {
            *slot.0.lock() = Some(Err(anyhow!(error.into())));
            slot.1.notify_all();
            true
        } else {
            false
        }
    }

    /// Waits for a response on a slot with a timeout.
    pub fn wait_for_response(
        slot: &ResponseSlot,
        timeout: Duration,
    ) -> Result<serde_json::Value> {
        let mut guard = slot.0.lock();
        if guard.is_none() {
            let wait_res = slot.1.wait_for(&mut guard, timeout);
            if wait_res.timed_out() && guard.is_none() {
                return Err(anyhow!("JSON-RPC request timed out after {:?}", timeout));
            }
        }

        guard
            .take()
            .unwrap_or_else(|| Err(anyhow!("No response received")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rpc_tracker_correlation() {
        let tracker = RpcTracker::new();
        let id = tracker.next_request_id();
        let slot = tracker.register(id);

        let t_slot = slot.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            *t_slot.0.lock() = Some(Ok(serde_json::json!({"status": "ok"})));
            t_slot.1.notify_all();
        });

        let res = RpcTracker::wait_for_response(&slot, Duration::from_millis(500)).unwrap();
        assert_eq!(res["status"], "ok");
    }
}
