use std::path::Path;
use tree_sitter::{Language, Node, Parser};

use crate::models::{EntityKind, Provenance, RelationKind, Relationship, SemanticEntity};

pub struct AstParser;

impl AstParser {
    pub fn parse_file<P: AsRef<Path>>(
        file_path: P,
        source_code: &str,
        git_oid: Option<&str>,
    ) -> (Vec<SemanticEntity>, Vec<Relationship>) {
        let path_str = file_path.as_ref().to_string_lossy().replace('\\', "/");
        let ext = file_path
            .as_ref()
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("");

        let language: Option<Language> = match ext {
            "rs" => Some(tree_sitter_rust::LANGUAGE.into()),
            "c" | "h" => Some(tree_sitter_c::LANGUAGE.into()),
            "lua" => Some(tree_sitter_lua::LANGUAGE.into()),
            _ => None,
        };

        let Some(lang) = language else {
            return (Vec::new(), Vec::new());
        };

        let mut parser = Parser::new();
        if parser.set_language(&lang).is_err() {
            return (Vec::new(), Vec::new());
        }

        let Some(tree) = parser.parse(source_code, None) else {
            return (Vec::new(), Vec::new());
        };

        let mut entities = Vec::new();
        let mut relationships = Vec::new();
        let bytes = source_code.as_bytes();

        Self::walk_tree(
            tree.root_node(),
            bytes,
            &path_str,
            git_oid,
            ext,
            &mut entities,
            &mut relationships,
        );

        (entities, relationships)
    }

    fn walk_tree(
        node: Node,
        bytes: &[u8],
        file_path: &str,
        git_oid: Option<&str>,
        ext: &str,
        entities: &mut Vec<SemanticEntity>,
        relationships: &mut Vec<Relationship>,
    ) {
        let kind_str = node.kind();
        let start_pos = node.start_position();
        let end_pos = node.end_position();

        let mut found_entity = None;

        match ext {
            "rs" => match kind_str {
                "function_item" => {
                    if let Some(name_node) = node.child_by_field_name("name") {
                        let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                        let is_test = Self::is_rust_test(node, bytes);
                        found_entity = Some((
                            if is_test {
                                EntityKind::Test
                            } else {
                                EntityKind::Function
                            },
                            name,
                        ));
                    }
                }
                "struct_item" | "enum_item" | "union_item" => {
                    if let Some(name_node) = node.child_by_field_name("name") {
                        let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                        found_entity = Some((EntityKind::Type, name));
                    }
                }
                "trait_item" => {
                    if let Some(name_node) = node.child_by_field_name("name") {
                        let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                        found_entity = Some((EntityKind::Trait, name));
                    }
                }
                "mod_item" => {
                    if let Some(name_node) = node.child_by_field_name("name") {
                        let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                        found_entity = Some((EntityKind::Module, name));
                    }
                }
                _ => {}
            },
            "c" | "h" => match kind_str {
                "function_definition" => {
                    if let Some(decl) = node.child_by_field_name("declarator") {
                        let name = Self::extract_c_fn_name(decl, bytes);
                        if !name.is_empty() {
                            found_entity = Some((EntityKind::Function, name));
                        }
                    }
                }
                "struct_specifier" | "enum_specifier" | "type_definition" => {
                    if let Some(name_node) = node.child_by_field_name("name") {
                        let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                        found_entity = Some((EntityKind::Type, name));
                    }
                }
                _ => {}
            },
            "lua" => match kind_str {
                "function_declaration" => {
                    if let Some(name_node) = node.child_by_field_name("name") {
                        let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                        found_entity = Some((EntityKind::Function, name));
                    }
                }
                "local_function" => {
                    if let Some(name_node) = node.child_by_field_name("name") {
                        let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                        found_entity = Some((EntityKind::Function, name));
                    }
                }
                "function_definition" => {
                    // anonymous function or rhs of assignment
                    if let Some(parent) = node.parent() {
                        if parent.kind() == "variable_declaration" || parent.kind() == "assignment_statement" {
                            let name = parent.utf8_text(bytes).unwrap_or("").lines().next().unwrap_or("").to_string();
                            let clean_name = name.split('=').next().unwrap_or("").trim().to_string();
                            if !clean_name.is_empty() {
                                found_entity = Some((EntityKind::Function, clean_name));
                            }
                        }
                    }
                }
                _ => {}
            },
            _ => {}
        }

        if let Some((kind, name)) = found_entity {
            let qualified_name = format!("{}::{}", file_path, name);
            let id = format!("{}:{}:{}", file_path, start_pos.row + 1, name);

            entities.push(SemanticEntity {
                id,
                kind,
                name,
                qualified_name,
                file_path: file_path.to_string(),
                start_line: start_pos.row + 1,
                end_line: end_pos.row + 1,
                start_col: start_pos.column + 1,
                end_col: end_pos.column + 1,
                git_oid: git_oid.map(|s| s.to_string()),
            });
        }

        // Detect calls: call_expression in Rust/C, function_call in Lua
        if kind_str == "call_expression" || kind_str == "function_call" {
            let callee_text = if let Some(fn_node) = node.child_by_field_name("function") {
                fn_node.utf8_text(bytes).unwrap_or("").to_string()
            } else if let Some(fn_node) = node.child_by_field_name("name") {
                fn_node.utf8_text(bytes).unwrap_or("").to_string()
            } else {
                String::new()
            };

            if !callee_text.is_empty() {
                // Determine enclosing function
                if let Some(enclosing) = Self::find_enclosing_function(node, bytes, ext) {
                    let source_id = format!("{}:{}:{}", file_path, enclosing.1, enclosing.0);
                    let target_id = callee_text.clone();

                    relationships.push(Relationship {
                        source_id,
                        target_id,
                        kind: RelationKind::Calls,
                        confidence: 0.95,
                        provenance: Provenance {
                            source_type: "ast".to_string(),
                            citations: vec![format!("{}:{}", file_path, start_pos.row + 1)],
                            details: format!("Direct call to {} at line {}", callee_text, start_pos.row + 1),
                        },
                    });
                }
            }
        }

        // Recurse children
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            Self::walk_tree(
                child,
                bytes,
                file_path,
                git_oid,
                ext,
                entities,
                relationships,
            );
        }
    }

    fn is_rust_test(node: Node, bytes: &[u8]) -> bool {
        let mut prev = node.prev_sibling();
        while let Some(sibling) = prev {
            if sibling.kind() == "attribute_item" {
                let text = sibling.utf8_text(bytes).unwrap_or("");
                if text.contains("test") {
                    return true;
                }
            } else if sibling.kind() != "line_comment" && sibling.kind() != "block_comment" {
                break;
            }
            prev = sibling.prev_sibling();
        }
        false
    }

    fn extract_c_fn_name(decl: Node, bytes: &[u8]) -> String {
        if decl.kind() == "identifier" {
            return decl.utf8_text(bytes).unwrap_or("").to_string();
        }
        if let Some(direct) = decl.child_by_field_name("declarator") {
            return Self::extract_c_fn_name(direct, bytes);
        }
        decl.utf8_text(bytes).unwrap_or("").to_string()
    }

    fn find_enclosing_function(
        node: Node,
        bytes: &[u8],
        ext: &str,
    ) -> Option<(String, usize)> {
        let mut current = node.parent();
        while let Some(parent) = current {
            let pk = parent.kind();
            if (ext == "rs" && pk == "function_item")
                || ((ext == "c" || ext == "h") && pk == "function_definition")
                || (ext == "lua" && (pk == "function_declaration" || pk == "local_function"))
            {
                if let Some(name_node) = parent.child_by_field_name("name") {
                    let name = name_node.utf8_text(bytes).unwrap_or("").to_string();
                    let line = parent.start_position().row + 1;
                    return Some((name, line));
                }
            }
            current = parent.parent();
        }
        None
    }
}
