use crate::generated::types::{AgentSendPromptParams, StreamEvent};
use crate::CodeLiteContext;
use code_lite_agent::llm::ChatMessage;

pub fn handle_send_prompt(
    ctx: *mut CodeLiteContext,
    params: AgentSendPromptParams,
) -> Result<StreamEvent, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let session_id = "default-session";
    let _ = ctx.session_store.create_session(session_id, "Core API Chat");

    let messages = vec![ChatMessage {
        role: "user".into(),
        content: params.prompt.clone(),
    }];

    let response = ctx
        .llm_provider
        .complete(&messages, None)
        .map_err(|e| format!("LLM completion failed: {}", e))?;

    Ok(StreamEvent {
        event_type: if params.stream { "content" } else { "done" }.into(),
        payload: response.content,
        is_done: true,
    })
}
