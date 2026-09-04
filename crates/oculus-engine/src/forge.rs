use std::collections::HashSet;
use crate::db::Database;
use crate::models::{ForgeArtifact, SemanticEntity, TraceabilityLink};

pub struct ForgeTraceabilityLinker;

impl ForgeTraceabilityLinker {
    pub fn link_artifact_to_code(
        db: &Database,
        artifact: &ForgeArtifact,
    ) -> Vec<TraceabilityLink> {
        let mut links = Vec::new();
        let mut seen_entities = HashSet::new();

        let mut corpus = String::new();
        if let Some(ref title) = artifact.title {
            corpus.push_str(title);
            corpus.push('\n');
        }
        if let Some(ref body) = artifact.body {
            corpus.push_str(body);
            corpus.push('\n');
        }
        for comment in &artifact.comments {
            corpus.push_str(&comment.body);
            corpus.push('\n');
        }

        if corpus.trim().is_empty() {
            return Vec::new();
        }

        // 1. Extract backticked symbols: `identifier`
        let backticked = Self::extract_backticked_symbols(&corpus);

        // 2. Query entities and check for matches
        let all_entities = Self::get_all_known_entities(db);

        for entity in &all_entities {
            let mut matches_backtick = false;
            let mut matches_token = false;
            let mut matched_evidence = Vec::new();

            // Check if entity name is explicitly backticked in forge discussion
            if backticked.contains(&entity.name) {
                matches_backtick = true;
                matched_evidence.push(format!("Symbol `{}` explicitly cited in forge discussion", entity.name));
            }

            // Check if full qualified name appears in corpus
            if corpus.contains(&entity.qualified_name) {
                matches_token = true;
                matched_evidence.push(format!("Qualified symbol `{}` cited in text", entity.qualified_name));
            } else if entity.name.len() >= 4 && corpus.contains(&entity.name) {
                // Check standalone word match
                let pattern = format!(" {} ", entity.name);
                let pattern_paren = format!("{}(", entity.name);
                let pattern_dot = format!(".{}", entity.name);
                let pattern_colon = format!(":{}", entity.name);

                if corpus.contains(&pattern)
                    || corpus.contains(&pattern_paren)
                    || corpus.contains(&pattern_dot)
                    || corpus.contains(&pattern_colon)
                {
                    matches_token = true;
                    matched_evidence.push(format!("Identifier token `{}` referenced in context", entity.name));
                }
            }

            // Check if file path is cited
            let file_base = std::path::Path::new(&entity.file_path)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("");

            let file_mentioned = !file_base.is_empty() && corpus.contains(file_base);
            if file_mentioned {
                matched_evidence.push(format!("Containing source file `{}` mentioned", entity.file_path));
            }

            if (matches_backtick || matches_token) && seen_entities.insert(entity.id.clone()) {
                let confidence = if matches_backtick && file_mentioned {
                    0.98
                } else if matches_backtick {
                    0.92
                } else if matches_token && file_mentioned {
                    0.85
                } else {
                    0.72
                };

                let reason = if matches_backtick {
                    "Explicit symbol citation in forge discussion".to_string()
                } else {
                    "Lexical identifier and structural reference in forge discussion".to_string()
                };

                links.push(TraceabilityLink {
                    forge_item: format!("{}:{}", artifact.kind, artifact.id),
                    target_entity: entity.clone(),
                    confidence,
                    match_reason: reason,
                    evidence: matched_evidence,
                });
            }
        }

        links.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap_or(std::cmp::Ordering::Equal));
        links.truncate(15);
        links
    }

    fn extract_backticked_symbols(text: &str) -> HashSet<String> {
        let mut symbols = HashSet::new();
        let mut in_backtick = false;
        let mut current = String::new();

        for c in text.chars() {
            if c == '`' {
                if in_backtick {
                    let s = current.trim().to_string();
                    if !s.is_empty() && !s.contains(' ') && !s.contains('\n') {
                        symbols.insert(s);
                    }
                    current.clear();
                    in_backtick = false;
                } else {
                    in_backtick = true;
                }
            } else if in_backtick {
                current.push(c);
            }
        }

        symbols
    }

    fn get_all_known_entities(db: &Database) -> Vec<SemanticEntity> {
        db.get_all_entities().unwrap_or_default()
    }
}
