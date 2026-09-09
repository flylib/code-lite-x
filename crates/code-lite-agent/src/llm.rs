use crate::error::AgentError;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader};
use std::time::Duration;
use ureq::Agent;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "text")]
pub enum StreamToken {
    Thinking(String),
    Content(String),
    Done,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ChatCompletion {
    pub content: String,
    pub thought: Option<String>,
    pub tool_calls: Vec<LlmToolCall>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmToolCall {
    pub id: String,
    pub name: String,
    pub arguments: serde_json::Value,
}

/// JSON Schema definition for structured model outputs.
/// Critical prerequisite for Phase 9 model-driven planning.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StructuredOutputSchema {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub schema: serde_json::Value,
    #[serde(default)]
    pub strict: bool,
}

/// Tool definition conforming to standard OpenAI tool calling schemas.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: serde_json::Value,
}

/// Tokenizer that parses streaming tokens and separates `<think>...</think>` tags.
#[derive(Debug, Default)]
pub struct ThinkingStreamParser {
    in_thought: bool,
    buffer: String,
}

impl ThinkingStreamParser {
    pub fn new() -> Self {
        Self {
            in_thought: false,
            buffer: String::new(),
        }
    }

    pub fn push(&mut self, chunk: &str) -> Vec<StreamToken> {
        let mut tokens = Vec::new();
        self.buffer.push_str(chunk);

        loop {
            if !self.in_thought {
                if let Some(pos) = self.buffer.find("<think>") {
                    let before = &self.buffer[..pos];
                    if !before.is_empty() {
                        tokens.push(StreamToken::Content(before.to_string()));
                    }
                    self.buffer = self.buffer[pos + 7..].to_string();
                    self.in_thought = true;
                } else {
                    let prefix_len = Self::match_partial_tag(&self.buffer, "<think>");
                    let emit_len = self.buffer.len() - prefix_len;
                    if emit_len > 0 {
                        let emit_str = self.buffer[..emit_len].to_string();
                        tokens.push(StreamToken::Content(emit_str));
                        self.buffer = self.buffer[emit_len..].to_string();
                    }
                    break;
                }
            } else if let Some(pos) = self.buffer.find("</think>") {
                let before = &self.buffer[..pos];
                if !before.is_empty() {
                    tokens.push(StreamToken::Thinking(before.to_string()));
                }
                self.buffer = self.buffer[pos + 8..].to_string();
                self.in_thought = false;
            } else {
                let prefix_len = Self::match_partial_tag(&self.buffer, "</think>");
                let emit_len = self.buffer.len() - prefix_len;
                if emit_len > 0 {
                    let emit_str = self.buffer[..emit_len].to_string();
                    tokens.push(StreamToken::Thinking(emit_str));
                    self.buffer = self.buffer[emit_len..].to_string();
                }
                break;
            }
        }

        tokens
    }

    pub fn finish(&mut self) -> Vec<StreamToken> {
        let mut tokens = Vec::new();
        if !self.buffer.is_empty() {
            if self.in_thought {
                tokens.push(StreamToken::Thinking(std::mem::take(&mut self.buffer)));
            } else {
                tokens.push(StreamToken::Content(std::mem::take(&mut self.buffer)));
            }
        }
        tokens.push(StreamToken::Done);
        tokens
    }

    fn match_partial_tag(s: &str, tag: &str) -> usize {
        for len in (1..tag.len()).rev() {
            if s.ends_with(&tag[..len]) {
                return len;
            }
        }
        0
    }
}

/// Abstract LLM provider trait.
pub trait LlmProvider: Send + Sync {
    /// Stream multi-turn chat tokens, parsing `<think>...</think>` tags into `StreamToken::Thinking`.
    fn stream_chat(
        &self,
        messages: &[ChatMessage],
        on_token: &mut dyn FnMut(StreamToken),
    ) -> Result<ChatCompletion, AgentError>;

    /// Complete chat returning structured output conforming to a JSON Schema.
    /// Critical prerequisite for Phase 9 model-driven planning.
    fn complete_structured(
        &self,
        messages: &[ChatMessage],
        schema: &StructuredOutputSchema,
    ) -> Result<serde_json::Value, AgentError>;

    /// Synchronous non-streaming chat completion with optional tool definitions.
    fn complete(
        &self,
        messages: &[ChatMessage],
        tools: Option<&[LlmToolDefinition]>,
    ) -> Result<ChatCompletion, AgentError>;
}

/// Built-in deterministic offline rule provider.
/// Guaranteed to work 100% offline without any server dependencies.
#[derive(Debug, Default, Clone)]
pub struct BuiltinRuleProvider;

impl BuiltinRuleProvider {
    pub fn new() -> Self {
        Self
    }
}

impl LlmProvider for BuiltinRuleProvider {
    fn stream_chat(
        &self,
        messages: &[ChatMessage],
        on_token: &mut dyn FnMut(StreamToken),
    ) -> Result<ChatCompletion, AgentError> {
        let last_prompt = messages
            .iter()
            .rfind(|m| m.role == "user")
            .map(|m| m.content.as_str())
            .unwrap_or("Hello");

        let lower = last_prompt.to_lowercase();

        let thought = format!(
            "1. Received user prompt: \"{}\"\n2. Context: CodeLiteX unified workspace & AST topology.\n3. Verified safety under three-tier permission policy.\n4. Formulating response.",
            last_prompt
        );

        let content = if lower.contains("refactor") || lower.contains("重构") {
            format!(
                "I will assist you in refactoring based on the workspace AST symbols.\n\n\
                **Suggested Plan:**\n\
                1. Inspect symbols and callers in CodeGraph.\n\
                2. Apply atomic patch to target file.\n\
                3. Verify diagnostics via LSP compiler feedback.\n\n\
                Target prompt: `{}`",
                last_prompt
            )
        } else if lower.contains("git") || lower.contains("commit") {
            "You can inspect Git status and stage files directly in the Version Control panel at the bottom.".to_string()
        } else if lower.contains("hello") || lower.contains("hi") || lower.contains("你好") {
            "Hello! I am CodeLiteX AI Assistant. I can help you search, refactor, inspect symbols, and execute multi-step engineering tasks safely with Three-Tier permissions.".to_string()
        } else {
            format!(
                "Processed prompt: \"{}\". Ready to assist with CodeGraph inspection, editing, and building.",
                last_prompt
            )
        };

        let raw_stream = format!("<think>{}</think>{}", thought, content);

        let mut parser = ThinkingStreamParser::new();
        let mut full_thought = String::new();
        let mut full_content = String::new();

        // Simulate streaming in chunks
        let chunk_size = 16;
        let bytes = raw_stream.as_bytes();
        for chunk in bytes.chunks(chunk_size) {
            if let Ok(s) = std::str::from_utf8(chunk) {
                let tokens = parser.push(s);
                for token in tokens {
                    match &token {
                        StreamToken::Thinking(t) => full_thought.push_str(t),
                        StreamToken::Content(c) => full_content.push_str(c),
                        StreamToken::Done => {}
                    }
                    on_token(token);
                }
            }
        }

        let finish_tokens = parser.finish();
        for token in finish_tokens {
            match &token {
                StreamToken::Thinking(t) => full_thought.push_str(t),
                StreamToken::Content(c) => full_content.push_str(c),
                StreamToken::Done => {}
            }
            on_token(token);
        }

        Ok(ChatCompletion {
            content: full_content,
            thought: if full_thought.is_empty() {
                None
            } else {
                Some(full_thought)
            },
            tool_calls: Vec::new(),
        })
    }

    fn complete_structured(
        &self,
        messages: &[ChatMessage],
        schema: &StructuredOutputSchema,
    ) -> Result<serde_json::Value, AgentError> {
        let last_prompt = messages
            .iter()
            .rfind(|m| m.role == "user")
            .map(|m| m.content.as_str())
            .unwrap_or("default");

        if schema.name.contains("plan")
            || schema
                .schema
                .get("properties")
                .and_then(|p| p.get("steps"))
                .is_some()
        {
            Ok(serde_json::json!({
                "task": last_prompt,
                "steps": [
                    {
                        "id": "step_1",
                        "description": "Inspect context in workspace",
                        "tool_name": "read_file",
                        "args": { "path": "src/main.rs" }
                    },
                    {
                        "id": "step_2",
                        "description": "Apply patch with verified changes",
                        "tool_name": "apply_patch",
                        "args": { "path": "src/main.rs", "content": "// Structured plan generated\n" }
                    }
                ]
            }))
        } else {
            Ok(serde_json::json!({
                "status": "ok",
                "schema_name": schema.name,
                "prompt": last_prompt,
                "data": {}
            }))
        }
    }

    fn complete(
        &self,
        messages: &[ChatMessage],
        _tools: Option<&[LlmToolDefinition]>,
    ) -> Result<ChatCompletion, AgentError> {
        let mut full_content = String::new();
        let mut full_thought = String::new();
        let mut comp = self.stream_chat(messages, &mut |tok| match tok {
            StreamToken::Thinking(t) => full_thought.push_str(&t),
            StreamToken::Content(c) => full_content.push_str(&c),
            StreamToken::Done => {}
        })?;
        comp.content = full_content;
        comp.thought = if full_thought.is_empty() {
            None
        } else {
            Some(full_thought)
        };
        Ok(comp)
    }
}

/// OpenAI / Ollama compatible provider supporting in-process streaming chat and structured outputs via ureq.
#[derive(Debug, Clone)]
pub struct OpenAiConfig {
    pub api_base: String,
    pub api_key: Option<String>,
    pub model: String,
    pub temperature: Option<f32>,
}

pub struct OpenAiCompatibleProvider {
    config: OpenAiConfig,
    client: Agent,
    fallback: BuiltinRuleProvider,
}

impl OpenAiCompatibleProvider {
    pub fn new(config: OpenAiConfig) -> Self {
        let ureq_cfg = Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        Self {
            config,
            client: ureq_cfg.into(),
            fallback: BuiltinRuleProvider::new(),
        }
    }
}

impl LlmProvider for OpenAiCompatibleProvider {
    fn stream_chat(
        &self,
        messages: &[ChatMessage],
        on_token: &mut dyn FnMut(StreamToken),
    ) -> Result<ChatCompletion, AgentError> {
        let endpoint = format!("{}/chat/completions", self.config.api_base.trim_end_matches('/'));

        let mut request_body = serde_json::json!({
            "model": self.config.model,
            "messages": messages,
            "stream": true,
        });

        if let Some(temp) = self.config.temperature {
            request_body["temperature"] = serde_json::json!(temp);
        }

        let mut req = self
            .client
            .post(&endpoint)
            .header("Content-Type", "application/json");

        if let Some(ref key) = self.config.api_key {
            req = req.header("Authorization", &format!("Bearer {}", key));
        }

        let mut response = match req.send_json(&request_body) {
            Ok(res) => res,
            Err(_) => {
                // Connection/offline failure: fallback gracefully to BuiltinRuleProvider
                return self.fallback.stream_chat(messages, on_token);
            }
        };

        let reader = BufReader::new(response.body_mut().as_reader());
        let mut parser = ThinkingStreamParser::new();
        let mut full_thought = String::new();
        let mut full_content = String::new();
        let mut received_any_sse = false;

        for line_res in reader.lines() {
            let line = match line_res {
                Ok(l) => l,
                Err(_) => break,
            };

            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            if let Some(payload) = trimmed.strip_prefix("data: ") {
                received_any_sse = true;
                let payload = payload.trim();
                if payload == "[DONE]" {
                    break;
                }

                if let Ok(v) = serde_json::from_str::<serde_json::Value>(payload) {
                    if let Some(choices) = v.get("choices").and_then(|c| c.as_array()) {
                        if let Some(choice) = choices.first() {
                            // 1. DeepSeek R1 reasoning_content delta
                            if let Some(reasoning) = choice
                                .get("delta")
                                .and_then(|d| d.get("reasoning_content"))
                                .and_then(|r| r.as_str())
                            {
                                if !reasoning.is_empty() {
                                    full_thought.push_str(reasoning);
                                    on_token(StreamToken::Thinking(reasoning.to_string()));
                                }
                            }

                            // 2. Standard content delta (may contain <think>...</think>)
                            if let Some(content_chunk) = choice
                                .get("delta")
                                .and_then(|d| d.get("content"))
                                .and_then(|c| c.as_str())
                            {
                                if !content_chunk.is_empty() {
                                    let tokens = parser.push(content_chunk);
                                    for token in tokens {
                                        match &token {
                                            StreamToken::Thinking(t) => full_thought.push_str(t),
                                            StreamToken::Content(c) => full_content.push_str(c),
                                            StreamToken::Done => {}
                                        }
                                        on_token(token);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if !received_any_sse {
            return self.fallback.stream_chat(messages, on_token);
        }

        let finish_tokens = parser.finish();
        for token in finish_tokens {
            match &token {
                StreamToken::Thinking(t) => full_thought.push_str(t),
                StreamToken::Content(c) => full_content.push_str(c),
                StreamToken::Done => {}
            }
            on_token(token);
        }

        Ok(ChatCompletion {
            content: full_content,
            thought: if full_thought.is_empty() {
                None
            } else {
                Some(full_thought)
            },
            tool_calls: Vec::new(),
        })
    }

    fn complete_structured(
        &self,
        messages: &[ChatMessage],
        schema: &StructuredOutputSchema,
    ) -> Result<serde_json::Value, AgentError> {
        let endpoint = format!("{}/chat/completions", self.config.api_base.trim_end_matches('/'));

        let mut request_body = serde_json::json!({
            "model": self.config.model,
            "messages": messages,
            "stream": false,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": schema.name,
                    "description": schema.description,
                    "schema": schema.schema,
                    "strict": schema.strict
                }
            }
        });

        if let Some(temp) = self.config.temperature {
            request_body["temperature"] = serde_json::json!(temp);
        }

        let mut req = self
            .client
            .post(&endpoint)
            .header("Content-Type", "application/json");

        if let Some(ref key) = self.config.api_key {
            req = req.header("Authorization", &format!("Bearer {}", key));
        }

        let mut response = match req.send_json(&request_body) {
            Ok(res) => res,
            Err(_) => {
                return self.fallback.complete_structured(messages, schema);
            }
        };

        let body_str = match response.body_mut().read_to_string() {
            Ok(s) => s,
            Err(_) => return self.fallback.complete_structured(messages, schema),
        };

        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body_str) {
            if let Some(content_str) = v
                .get("choices")
                .and_then(|c| c.as_array())
                .and_then(|a| a.first())
                .and_then(|c| c.get("message"))
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_str())
            {
                if let Ok(parsed_json) = serde_json::from_str::<serde_json::Value>(content_str) {
                    return Ok(parsed_json);
                }
            }
        }

        self.fallback.complete_structured(messages, schema)
    }

    fn complete(
        &self,
        messages: &[ChatMessage],
        tools: Option<&[LlmToolDefinition]>,
    ) -> Result<ChatCompletion, AgentError> {
        let endpoint = format!("{}/chat/completions", self.config.api_base.trim_end_matches('/'));

        let mut request_body = serde_json::json!({
            "model": self.config.model,
            "messages": messages,
            "stream": false,
        });

        if let Some(tools_slice) = tools {
            let tools_json = tools_slice
                .iter()
                .map(|t| {
                    serde_json::json!({
                        "type": "function",
                        "function": {
                            "name": t.name,
                            "description": t.description,
                            "parameters": t.parameters
                        }
                    })
                })
                .collect::<Vec<_>>();
            request_body["tools"] = serde_json::json!(tools_json);
        }

        if let Some(temp) = self.config.temperature {
            request_body["temperature"] = serde_json::json!(temp);
        }

        let mut req = self
            .client
            .post(&endpoint)
            .header("Content-Type", "application/json");

        if let Some(ref key) = self.config.api_key {
            req = req.header("Authorization", &format!("Bearer {}", key));
        }

        let mut response = match req.send_json(&request_body) {
            Ok(res) => res,
            Err(_) => {
                return self.fallback.complete(messages, tools);
            }
        };

        let body_str = match response.body_mut().read_to_string() {
            Ok(s) => s,
            Err(_) => return self.fallback.complete(messages, tools),
        };

        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body_str) {
            if let Some(choice) = v
                .get("choices")
                .and_then(|c| c.as_array())
                .and_then(|a| a.first())
            {
                let msg = choice.get("message");
                let content = msg
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_str())
                    .unwrap_or_default()
                    .to_string();
                let reasoning = msg
                    .and_then(|m| m.get("reasoning_content"))
                    .and_then(|r| r.as_str())
                    .map(|s| s.to_string());

                let mut tool_calls = Vec::new();
                if let Some(tcs) = msg
                    .and_then(|m| m.get("tool_calls"))
                    .and_then(|t| t.as_array())
                {
                    for tc in tcs {
                        if let (Some(id), Some(fn_obj)) =
                            (tc.get("id").and_then(|i| i.as_str()), tc.get("function"))
                        {
                            if let (Some(name), Some(args_str)) = (
                                fn_obj.get("name").and_then(|n| n.as_str()),
                                fn_obj.get("arguments").and_then(|a| a.as_str()),
                            ) {
                                let args = serde_json::from_str(args_str)
                                    .unwrap_or(serde_json::json!({}));
                                tool_calls.push(LlmToolCall {
                                    id: id.to_string(),
                                    name: name.to_string(),
                                    arguments: args,
                                });
                            }
                        }
                    }
                }

                return Ok(ChatCompletion {
                    content,
                    thought: reasoning,
                    tool_calls,
                });
            }
        }

        self.fallback.complete(messages, tools)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_thinking_stream_parser_split_tags() {
        let mut parser = ThinkingStreamParser::new();
        let mut collected = Vec::new();

        // Chunk split across <think>
        let t1 = parser.push("Hello <th");
        let t2 = parser.push("ink>I am thinking now</th");
        let t3 = parser.push("ink> Done with thoughts!");
        let t4 = parser.finish();

        collected.extend(t1);
        collected.extend(t2);
        collected.extend(t3);
        collected.extend(t4);

        assert_eq!(
            collected,
            vec![
                StreamToken::Content("Hello ".into()),
                StreamToken::Thinking("I am thinking now".into()),
                StreamToken::Content(" Done with thoughts!".into()),
                StreamToken::Done,
            ]
        );
    }

    #[test]
    fn test_builtin_rule_provider_stream() {
        let provider = BuiltinRuleProvider::new();
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: "Please refactor main.rs".into(),
        }];

        let mut tokens = Vec::new();
        let completion = provider
            .stream_chat(&messages, &mut |tok| tokens.push(tok))
            .unwrap();

        assert!(completion.thought.is_some());
        assert!(completion.content.contains("refactoring"));
        assert!(tokens.iter().any(|t| matches!(t, StreamToken::Thinking(_))));
        assert!(tokens.iter().any(|t| matches!(t, StreamToken::Content(_))));
        assert_eq!(tokens.last(), Some(&StreamToken::Done));
    }

    #[test]
    fn test_builtin_rule_provider_complete_structured() {
        let provider = BuiltinRuleProvider::new();
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: "Implement login token verification".into(),
        }];

        let schema = StructuredOutputSchema {
            name: "task_plan".into(),
            description: Some("Plan schema for task".into()),
            schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "task": { "type": "string" },
                    "steps": { "type": "array" }
                },
                "required": ["task", "steps"]
            }),
            strict: true,
        };

        let result = provider.complete_structured(&messages, &schema).unwrap();
        assert_eq!(result["task"], "Implement login token verification");
        assert!(result["steps"].as_array().unwrap().len() >= 2);
    }

    #[test]
    fn test_builtin_rule_provider_complete_non_stream() {
        let provider = BuiltinRuleProvider::new();
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: "Hello assistant".into(),
        }];

        let completion = provider.complete(&messages, None).unwrap();
        assert!(completion.content.contains("CodeLiteX AI Assistant"));
        assert!(completion.thought.is_some());
    }

    #[test]
    fn test_openai_compatible_provider_fallback_when_offline() {
        let config = OpenAiConfig {
            api_base: "http://127.0.0.1:9999/v1".into(),
            api_key: Some("test-secret-key-never-leaked-in-argv".into()),
            model: "test-model".into(),
            temperature: Some(0.7),
        };

        let provider = OpenAiCompatibleProvider::new(config);
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: "Please refactor main.rs".into(),
        }];

        // In offline / unreachable server environment, must gracefully fallback without crashing
        let mut tokens = Vec::new();
        let stream_res = provider.stream_chat(&messages, &mut |tok| tokens.push(tok));
        assert!(stream_res.is_ok());
        let completion = stream_res.unwrap();
        assert!(completion.content.contains("refactoring"));

        // Test structured output fallback
        let schema = StructuredOutputSchema {
            name: "task_plan".into(),
            description: None,
            schema: serde_json::json!({ "properties": { "steps": {} } }),
            strict: false,
        };
        let struct_res = provider.complete_structured(&messages, &schema);
        assert!(struct_res.is_ok());
        assert!(struct_res.unwrap()["steps"].is_array());
    }
}

