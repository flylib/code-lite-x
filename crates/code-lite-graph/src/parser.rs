use crate::outline::OutlineNode;
use quote::ToTokens;
use regex::Regex;
use syn::spanned::Spanned;
use syn::visit::Visit;

#[derive(Debug, Clone)]
pub struct ParsedSymbol {
    pub symbol_key: String,
    pub name: String,
    pub kind: String,
    pub signature: Option<String>,
    pub line_start: usize,
    pub col_start: usize,
    pub line_end: usize,
    pub col_end: usize,
    pub scope_path: Option<String>,
    pub children: Vec<OutlineNode>,
}

impl ParsedSymbol {
    pub fn to_outline_node(&self) -> OutlineNode {
        OutlineNode {
            name: self.name.clone(),
            symbol_key: self.symbol_key.clone(),
            kind: self.kind.clone(),
            signature: self.signature.clone(),
            line_start: self.line_start,
            col_start: self.col_start,
            line_end: self.line_end,
            col_end: self.col_end,
            children: self.children.clone(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ParsedFile {
    pub language: String,
    pub symbols: Vec<ParsedSymbol>,
    pub imports: Vec<String>,
    pub calls: Vec<(String, usize)>, // (callee_name, call_line)
}

/// Visitor to collect function/method calls from Rust AST.
struct RustCallVisitor {
    calls: Vec<(String, usize)>,
}

impl<'ast> Visit<'ast> for RustCallVisitor {
    fn visit_expr_call(&mut self, node: &'ast syn::ExprCall) {
        let line = node.span().start().line;
        if let syn::Expr::Path(p) = &*node.func {
            if let Some(ident) = p.path.segments.last() {
                self.calls.push((ident.ident.to_string(), line));
            }
        }
        syn::visit::visit_expr_call(self, node);
    }

    fn visit_expr_method_call(&mut self, node: &'ast syn::ExprMethodCall) {
        let line = node.span().start().line;
        self.calls.push((node.method.to_string(), line));
        syn::visit::visit_expr_method_call(self, node);
    }
}

pub struct CodeParser;

impl CodeParser {
    /// Computes a stable, deterministic symbol_key.
    pub fn compute_symbol_key(
        lang: &str,
        rel_path: &str,
        kind: &str,
        scope: Option<&str>,
        name: &str,
    ) -> String {
        if let Some(s) = scope {
            format!("{}:{}:{}::{}::{}", lang, rel_path, kind, s, name)
        } else {
            format!("{}:{}:{}::{}", lang, rel_path, kind, name)
        }
    }

    /// Detects language from file path extension.
    pub fn detect_language(path: &str) -> &'static str {
        if path.ends_with(".rs") {
            "rust"
        } else if path.ends_with(".dart") {
            "dart"
        } else if path.ends_with(".py") {
            "python"
        } else if path.ends_with(".js") || path.ends_with(".jsx") {
            "javascript"
        } else if path.ends_with(".ts") || path.ends_with(".tsx") {
            "typescript"
        } else if path.ends_with(".go") {
            "go"
        } else if path.ends_with(".json") {
            "json"
        } else if path.ends_with(".toml") {
            "toml"
        } else if path.ends_with(".md") {
            "markdown"
        } else {
            "plaintext"
        }
    }

    /// Parses a file's content based on its language.
    pub fn parse(path: &str, content: &str) -> ParsedFile {
        let lang = Self::detect_language(path);
        match lang {
            "rust" => Self::parse_rust(path, content),
            "dart" | "python" | "javascript" | "typescript" | "go" => {
                Self::parse_generic(lang, path, content)
            }
            _ => ParsedFile {
                language: lang.to_string(),
                symbols: Vec::new(),
                imports: Vec::new(),
                calls: Vec::new(),
            },
        }
    }

    /// Full AST parsing for Rust code using `syn`.
    pub fn parse_rust(path: &str, content: &str) -> ParsedFile {
        let syntax_tree = match syn::parse_file(content) {
            Ok(tree) => tree,
            Err(_) => return Self::parse_generic("rust", path, content),
        };

        let mut symbols = Vec::new();
        let mut imports = Vec::new();

        for item in &syntax_tree.items {
            match item {
                syn::Item::Fn(f) => {
                    let name = f.sig.ident.to_string();
                    let sig_text = f.sig.to_token_stream().to_string();
                    let key = Self::compute_symbol_key("rust", path, "function", None, &name);
                    symbols.push(ParsedSymbol {
                        symbol_key: key,
                        name,
                        kind: "function".to_string(),
                        signature: Some(sig_text),
                        line_start: f.span().start().line,
                        col_start: f.span().start().column,
                        line_end: f.span().end().line,
                        col_end: f.span().end().column,
                        scope_path: None,
                        children: Vec::new(),
                    });
                }
                syn::Item::Struct(s) => {
                    let struct_name = s.ident.to_string();
                    let struct_key = Self::compute_symbol_key("rust", path, "struct", None, &struct_name);
                    let mut fields = Vec::new();
                    for field in &s.fields {
                        if let Some(ident) = &field.ident {
                            let field_name = ident.to_string();
                            let field_key = Self::compute_symbol_key(
                                "rust",
                                path,
                                "field",
                                Some(&struct_name),
                                &field_name,
                            );
                            fields.push(OutlineNode {
                                name: field_name,
                                symbol_key: field_key,
                                kind: "field".to_string(),
                                signature: Some(field.ty.to_token_stream().to_string()),
                                line_start: field.span().start().line,
                                col_start: field.span().start().column,
                                line_end: field.span().end().line,
                                col_end: field.span().end().column,
                                children: Vec::new(),
                            });
                        }
                    }
                    symbols.push(ParsedSymbol {
                        symbol_key: struct_key,
                        name: struct_name,
                        kind: "struct".to_string(),
                        signature: Some(format!("struct {}", s.ident)),
                        line_start: s.span().start().line,
                        col_start: s.span().start().column,
                        line_end: s.span().end().line,
                        col_end: s.span().end().column,
                        scope_path: None,
                        children: fields,
                    });
                }
                syn::Item::Enum(e) => {
                    let enum_name = e.ident.to_string();
                    let enum_key = Self::compute_symbol_key("rust", path, "enum", None, &enum_name);
                    let mut variants = Vec::new();
                    for v in &e.variants {
                        let variant_name = v.ident.to_string();
                        let variant_key = Self::compute_symbol_key(
                            "rust",
                            path,
                            "variant",
                            Some(&enum_name),
                            &variant_name,
                        );
                        variants.push(OutlineNode {
                            name: variant_name,
                            symbol_key: variant_key,
                            kind: "variant".to_string(),
                            signature: None,
                            line_start: v.span().start().line,
                            col_start: v.span().start().column,
                            line_end: v.span().end().line,
                            col_end: v.span().end().column,
                            children: Vec::new(),
                        });
                    }
                    symbols.push(ParsedSymbol {
                        symbol_key: enum_key,
                        name: enum_name,
                        kind: "enum".to_string(),
                        signature: Some(format!("enum {}", e.ident)),
                        line_start: e.span().start().line,
                        col_start: e.span().start().column,
                        line_end: e.span().end().line,
                        col_end: e.span().end().column,
                        scope_path: None,
                        children: variants,
                    });
                }
                syn::Item::Trait(t) => {
                    let trait_name = t.ident.to_string();
                    let trait_key = Self::compute_symbol_key("rust", path, "trait", None, &trait_name);
                    let mut items = Vec::new();
                    for ti in &t.items {
                        if let syn::TraitItem::Fn(tif) = ti {
                            let method_name = tif.sig.ident.to_string();
                            let method_key = Self::compute_symbol_key(
                                "rust",
                                path,
                                "method",
                                Some(&trait_name),
                                &method_name,
                            );
                            items.push(OutlineNode {
                                name: method_name,
                                symbol_key: method_key,
                                kind: "method".to_string(),
                                signature: Some(tif.sig.to_token_stream().to_string()),
                                line_start: tif.span().start().line,
                                col_start: tif.span().start().column,
                                line_end: tif.span().end().line,
                                col_end: tif.span().end().column,
                                children: Vec::new(),
                            });
                        }
                    }
                    symbols.push(ParsedSymbol {
                        symbol_key: trait_key,
                        name: trait_name,
                        kind: "trait".to_string(),
                        signature: Some(format!("trait {}", t.ident)),
                        line_start: t.span().start().line,
                        col_start: t.span().start().column,
                        line_end: t.span().end().line,
                        col_end: t.span().end().column,
                        scope_path: None,
                        children: items,
                    });
                }
                syn::Item::Impl(imp) => {
                    let self_ty_str = imp.self_ty.to_token_stream().to_string();
                    let trait_str = imp
                        .trait_
                        .as_ref()
                        .map(|(_, p, _)| format!("{} for ", p.to_token_stream()))
                        .unwrap_or_default();
                    let name = format!("impl {}{}", trait_str, self_ty_str);
                    let impl_key = Self::compute_symbol_key("rust", path, "impl", None, &name);

                    let mut methods = Vec::new();
                    for ii in &imp.items {
                        if let syn::ImplItem::Fn(iif) = ii {
                            let method_name = iif.sig.ident.to_string();
                            let method_key = Self::compute_symbol_key(
                                "rust",
                                path,
                                "method",
                                Some(&self_ty_str),
                                &method_name,
                            );
                            methods.push(OutlineNode {
                                name: method_name,
                                symbol_key: method_key,
                                kind: "method".to_string(),
                                signature: Some(iif.sig.to_token_stream().to_string()),
                                line_start: iif.span().start().line,
                                col_start: iif.span().start().column,
                                line_end: iif.span().end().line,
                                col_end: iif.span().end().column,
                                children: Vec::new(),
                            });
                        }
                    }

                    symbols.push(ParsedSymbol {
                        symbol_key: impl_key,
                        name,
                        kind: "impl".to_string(),
                        signature: Some(format!("impl {}", self_ty_str)),
                        line_start: imp.span().start().line,
                        col_start: imp.span().start().column,
                        line_end: imp.span().end().line,
                        col_end: imp.span().end().column,
                        scope_path: Some(self_ty_str),
                        children: methods,
                    });
                }
                syn::Item::Mod(m) => {
                    let mod_name = m.ident.to_string();
                    let mod_key = Self::compute_symbol_key("rust", path, "module", None, &mod_name);
                    symbols.push(ParsedSymbol {
                        symbol_key: mod_key,
                        name: mod_name,
                        kind: "module".to_string(),
                        signature: Some(format!("mod {}", m.ident)),
                        line_start: m.span().start().line,
                        col_start: m.span().start().column,
                        line_end: m.span().end().line,
                        col_end: m.span().end().column,
                        scope_path: None,
                        children: Vec::new(),
                    });
                }
                syn::Item::Use(u) => {
                    imports.push(u.to_token_stream().to_string());
                }
                _ => {}
            }
        }

        let mut call_visitor = RustCallVisitor { calls: Vec::new() };
        call_visitor.visit_file(&syntax_tree);

        ParsedFile {
            language: "rust".to_string(),
            symbols,
            imports,
            calls: call_visitor.calls,
        }
    }

    /// Fast regex-based scanner for Dart, Python, JavaScript, TypeScript, Go.
    pub fn parse_generic(lang: &str, path: &str, content: &str) -> ParsedFile {
        let mut symbols = Vec::new();
        let mut imports = Vec::new();
        let mut calls = Vec::new();

        let class_re = Regex::new(r"(?m)^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z0-9_]+)").unwrap();
        let func_re = Regex::new(r"(?m)^\s*(?:export\s+)?(?:async\s+)?(?:def|function)\s+([A-Za-z0-9_]+)\s*\((.*?)\)").unwrap();
        let dart_method_re = Regex::new(r"(?m)^\s*(?:@override\s+)?(?:[A-Za-z0-9_<>,]+\s+)?([A-Za-z0-9_]+)\s*\((.*?)\)\s*(?:async\s*)?[{=]").unwrap();
        let import_re = Regex::new(r"(?m)^\s*(?:import|from|use)\s+(.+)").unwrap();
        let call_re = Regex::new(r"([A-Za-z0-9_]+)\s*\(").unwrap();

        for (idx, line) in content.lines().enumerate() {
            let line_no = idx + 1;

            if let Some(caps) = import_re.captures(line) {
                imports.push(caps[1].trim().to_string());
                continue;
            }

            if let Some(caps) = class_re.captures(line) {
                let name = caps[1].to_string();
                let key = Self::compute_symbol_key(lang, path, "class", None, &name);
                symbols.push(ParsedSymbol {
                    symbol_key: key,
                    name,
                    kind: "class".to_string(),
                    signature: Some(line.trim().to_string()),
                    line_start: line_no,
                    col_start: 0,
                    line_end: line_no,
                    col_end: line.len(),
                    scope_path: None,
                    children: Vec::new(),
                });
                continue;
            }

            if let Some(caps) = func_re.captures(line) {
                let name = caps[1].to_string();
                let key = Self::compute_symbol_key(lang, path, "function", None, &name);
                symbols.push(ParsedSymbol {
                    symbol_key: key,
                    name,
                    kind: "function".to_string(),
                    signature: Some(line.trim().to_string()),
                    line_start: line_no,
                    col_start: 0,
                    line_end: line_no,
                    col_end: line.len(),
                    scope_path: None,
                    children: Vec::new(),
                });
                continue;
            }

            if lang == "dart" {
                if let Some(caps) = dart_method_re.captures(line) {
                    let name = caps[1].to_string();
                    if !["if", "for", "while", "switch", "catch"].contains(&name.as_str()) {
                        let key = Self::compute_symbol_key("dart", path, "method", None, &name);
                        symbols.push(ParsedSymbol {
                            symbol_key: key,
                            name,
                            kind: "method".to_string(),
                            signature: Some(line.trim().to_string()),
                            line_start: line_no,
                            col_start: 0,
                            line_end: line_no,
                            col_end: line.len(),
                            scope_path: None,
                            children: Vec::new(),
                        });
                    }
                }
            }

            for caps in call_re.captures_iter(line) {
                let callee = caps[1].to_string();
                if !["if", "for", "while", "switch", "catch", "return", "match"].contains(&callee.as_str()) {
                    calls.push((callee, line_no));
                }
            }
        }

        ParsedFile {
            language: lang.to_string(),
            symbols,
            imports,
            calls,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_rust_symbols_with_stable_keys() {
        let code = r#"
        pub struct EditorService {
            pub root_dir: String,
        }

        impl EditorService {
            pub fn start(&self) -> bool {
                true
            }
        }

        pub fn main_init() {}
        "#;

        let parsed = CodeParser::parse("crates/core/src/service.rs", code);
        assert_eq!(parsed.symbols.len(), 3);

        let s = parsed.symbols.iter().find(|x| x.name == "EditorService").unwrap();
        assert_eq!(s.symbol_key, "rust:crates/core/src/service.rs:struct::EditorService");
        assert_eq!(s.children.len(), 1);
        assert_eq!(s.children[0].symbol_key, "rust:crates/core/src/service.rs:field::EditorService::root_dir");

        let imp = parsed.symbols.iter().find(|x| x.name.contains("impl")).unwrap();
        assert_eq!(imp.children.len(), 1);
        assert_eq!(imp.children[0].symbol_key, "rust:crates/core/src/service.rs:method::EditorService::start");
    }
}
