use crate::buffer::TextBuffer;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenType {
    Keyword,
    Type,
    Function,
    String,
    Comment,
    Number,
    Operator,
    Punctuation,
    Identifier,
    Whitespace,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyntaxToken {
    pub col_start: usize,
    pub col_end: usize,
    pub token_type: TokenType,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LineTokens {
    pub line_number: usize,
    pub tokens: Vec<SyntaxToken>,
}

const RUST_KEYWORDS: &[&str] = &[
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
    "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
    "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
    "trait", "true", "type", "unsafe", "use", "where", "while",
];

const BUILTIN_TYPES: &[&str] = &[
    "bool", "char", "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64",
    "u128", "usize", "f32", "f64", "str", "String", "Option", "Result", "Vec", "Box", "Rc",
    "Arc", "Cell", "RefCell", "Mutex", "RwLock",
];

pub struct LineTokenizer;

impl LineTokenizer {
    /// Tokenizes a single line into classified syntax tokens with column ranges.
    pub fn tokenize_line(line: &str) -> Vec<SyntaxToken> {
        let mut tokens = Vec::new();
        let chars: Vec<char> = line.chars().collect();
        let len = chars.len();
        let mut i = 0;

        while i < len {
            let start = i;
            let c = chars[i];

            // 1. Whitespace
            if c.is_whitespace() {
                while i < len && chars[i].is_whitespace() {
                    i += 1;
                }
                tokens.push(SyntaxToken {
                    col_start: start,
                    col_end: i,
                    token_type: TokenType::Whitespace,
                    text: chars[start..i].iter().collect(),
                });
                continue;
            }

            // 2. Line Comments (// ...)
            if c == '/' && i + 1 < len && chars[i + 1] == '/' {
                tokens.push(SyntaxToken {
                    col_start: start,
                    col_end: len,
                    token_type: TokenType::Comment,
                    text: chars[start..len].iter().collect(),
                });
                break;
            }

            // 3. Strings ("..." or '...')
            if c == '"' || c == '\'' {
                let quote = c;
                i += 1;
                let mut escaped = false;
                while i < len {
                    let cur = chars[i];
                    if escaped {
                        escaped = false;
                    } else if cur == '\\' {
                        escaped = true;
                    } else if cur == quote {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
                tokens.push(SyntaxToken {
                    col_start: start,
                    col_end: i,
                    token_type: TokenType::String,
                    text: chars[start..i].iter().collect(),
                });
                continue;
            }

            // 4. Numbers
            if c.is_ascii_digit() {
                while i < len
                    && (chars[i].is_ascii_alphanumeric()
                        || chars[i] == '.'
                        || chars[i] == '_')
                {
                    i += 1;
                }
                tokens.push(SyntaxToken {
                    col_start: start,
                    col_end: i,
                    token_type: TokenType::Number,
                    text: chars[start..i].iter().collect(),
                });
                continue;
            }

            // 5. Identifiers, Keywords, Functions, Types
            if c.is_alphabetic() || c == '_' {
                while i < len && (chars[i].is_alphanumeric() || chars[i] == '_') {
                    i += 1;
                }
                let word: String = chars[start..i].iter().collect();

                // Lookahead for function call `foo(`
                let is_func = {
                    let mut look = i;
                    while look < len && chars[look].is_whitespace() {
                        look += 1;
                    }
                    look < len && chars[look] == '('
                };

                let token_type = if RUST_KEYWORDS.contains(&word.as_str()) {
                    TokenType::Keyword
                } else if BUILTIN_TYPES.contains(&word.as_str())
                    || (word.starts_with(|c: char| c.is_ascii_uppercase()) && !is_func)
                {
                    TokenType::Type
                } else if is_func {
                    TokenType::Function
                } else {
                    TokenType::Identifier
                };

                tokens.push(SyntaxToken {
                    col_start: start,
                    col_end: i,
                    token_type,
                    text: word,
                });
                continue;
            }

            // 6. Multi-char Operators (->, =>, ==, !=, <=, >=, &&, ||, ::)
            if i + 1 < len {
                let two_char: String = chars[i..i + 2].iter().collect();
                if matches!(
                    two_char.as_str(),
                    "->" | "=>" | "==" | "!=" | "<=" | ">=" | "&&" | "||" | "::" | "+=" | "-=" | "*=" | "/="
                ) {
                    i += 2;
                    tokens.push(SyntaxToken {
                        col_start: start,
                        col_end: i,
                        token_type: TokenType::Operator,
                        text: two_char,
                    });
                    continue;
                }
            }

            // 7. Single Operators & Punctuation
            let token_type = match c {
                '+' | '-' | '*' | '/' | '%' | '=' | '<' | '>' | '!' | '&' | '|' | '^' => {
                    TokenType::Operator
                }
                ';' | ',' | '.' | ':' | '(' | ')' | '{' | '}' | '[' | ']' | '?' => {
                    TokenType::Punctuation
                }
                _ => TokenType::Punctuation,
            };

            i += 1;
            tokens.push(SyntaxToken {
                col_start: start,
                col_end: i,
                token_type,
                text: c.to_string(),
            });
        }

        tokens
    }
}

/// Extracts syntax tokens for a specific viewport range `[start_line, end_line]` (0-indexed).
pub fn get_viewport_tokens(
    buffer: &TextBuffer,
    start_line: usize,
    end_line: usize,
) -> Vec<LineTokens> {
    let total_lines = buffer.len_lines();
    if total_lines == 0 {
        return Vec::new();
    }

    let start = start_line.min(total_lines - 1);
    let end = end_line.min(total_lines - 1);

    let mut result = Vec::with_capacity(end - start + 1);
    for line_idx in start..=end {
        let line_text = buffer.line_text(line_idx).unwrap_or_default();
        let tokens = LineTokenizer::tokenize_line(&line_text);
        result.push(LineTokens {
            line_number: line_idx,
            tokens,
        });
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_line_tokenizer_classification() {
        let line = "pub fn add(a: i32, b: i32) -> i32 { \"hello\" + 42 } // comment";
        let tokens = LineTokenizer::tokenize_line(line);

        let types: Vec<_> = tokens
            .iter()
            .filter(|t| t.token_type != TokenType::Whitespace)
            .map(|t| (t.token_type, t.text.as_str()))
            .collect();

        assert_eq!(types[0], (TokenType::Keyword, "pub"));
        assert_eq!(types[1], (TokenType::Keyword, "fn"));
        assert_eq!(types[2], (TokenType::Function, "add"));
        assert_eq!(types[3], (TokenType::Punctuation, "("));
        assert_eq!(types[4], (TokenType::Identifier, "a"));
        assert_eq!(types[5], (TokenType::Punctuation, ":"));
        assert_eq!(types[6], (TokenType::Type, "i32"));
        assert_eq!(types[11], (TokenType::Punctuation, ")"));
        assert_eq!(types[12], (TokenType::Operator, "->"));
        assert_eq!(types[13], (TokenType::Type, "i32"));
        assert_eq!(types[15], (TokenType::String, "\"hello\""));
        assert_eq!(types[16], (TokenType::Operator, "+"));
        assert_eq!(types[17], (TokenType::Number, "42"));
        assert_eq!(types[19], (TokenType::Comment, "// comment"));
    }

    #[test]
    fn test_viewport_tokens_streaming() {
        let code = "fn line0() {}\nfn line1() {}\nfn line2() {}\nfn line3() {}\n";
        let buffer = TextBuffer::from_str(code);

        let viewport = get_viewport_tokens(&buffer, 1, 2);
        assert_eq!(viewport.len(), 2);
        assert_eq!(viewport[0].line_number, 1);
        assert_eq!(viewport[1].line_number, 2);
    }
}
