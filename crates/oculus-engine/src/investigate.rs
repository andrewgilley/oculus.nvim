use std::fs;
use std::path::{Path, PathBuf};
use chrono::Utc;

use crate::coupling::ChangeCouplingMiner;
use crate::db::Database;
use crate::git::GitReader;
use crate::impact::ImpactAnalyzer;
use crate::mapper::GitSemanticMapper;
use crate::models::{
    BundleMetadata, EntityHistory, InvariantCheck, InvestigateFactBundle, SemanticEntity,
};
use crate::parser::AstParser;

pub struct Investigator;

impl Investigator {
    pub fn run_investigation<P: AsRef<Path>>(
        repo_root: P,
        target: Option<&str>,
        target_kind: Option<&str>,
        db_path: Option<&Path>,
    ) -> Result<InvestigateFactBundle, Box<dyn std::error::Error>> {
        let resolved_repo = GitReader::find_repo_root(repo_root.as_ref())
            .unwrap_or_else(|| repo_root.as_ref().to_path_buf());
        let repo_path = &resolved_repo;
        let mut db = match db_path {
            Some(p) => Database::open(p)?,
            None => Database::in_memory()?,
        };

        // 1. Scan and parse source code files in repository
        let source_files = Self::collect_source_files(repo_path);
        let head_oid = GitReader::current_head(repo_path);

        for path in &source_files {
            if let Ok(content) = fs::read_to_string(path) {
                let rel_path = path.strip_prefix(repo_path).unwrap_or(path);
                let (entities, rels) = AstParser::parse_file(rel_path, &content, head_oid.as_deref());
                if !entities.is_empty() {
                    let _ = db.insert_entities(&entities);
                }
                if !rels.is_empty() {
                    let _ = db.insert_relationships(&rels);
                }
            }
        }

        // 2. Mine Git commit history (up to 200 commits for co-change and entity change history)
        let commits = GitReader::commit_history(repo_path, 200);
        for c in &commits {
            let _ = db.insert_commit(c);
        }

        let co_changes = ChangeCouplingMiner::mine_co_changes(&commits, 2, 0.20);
        let _ = db.insert_co_changes(&co_changes);

        // 3. Resolve target diff hunks (specific commit, uncommitted working tree, or default HEAD)
        let hunks = match target {
            Some(commit_or_ref) if !commit_or_ref.is_empty() && commit_or_ref != "HEAD" => {
                GitReader::commit_diff_hunks(repo_path, commit_or_ref)
            }
            _ => {
                let uncommitted = GitReader::uncommitted_diff_hunks(repo_path);
                if !uncommitted.is_empty() {
                    uncommitted
                } else if let Some(ref head) = head_oid {
                    GitReader::commit_diff_hunks(repo_path, head)
                } else {
                    Vec::new()
                }
            }
        };

        // 4. Map diff hunks to semantic entities
        let target_oid = target.unwrap_or(head_oid.as_deref().unwrap_or("HEAD"));
        let mapped_changes = GitSemanticMapper::map_diff_to_entities(&db, target_oid, &hunks);

        let mut modified_entities: Vec<SemanticEntity> = Vec::new();
        let mut entity_histories: Vec<EntityHistory> = Vec::new();

        for (change, entity) in mapped_changes {
            let _ = db.insert_entity_changes(&[change]);
            if !modified_entities.iter().any(|e| e.id == entity.id) {
                if let Ok(history) = db.get_entity_history(&entity.id) {
                    entity_histories.push(history);
                }
                modified_entities.push(entity);
            }
        }

        // 5. Calculate structural impact (propagation surface)
        let impact = if !modified_entities.is_empty() {
            Some(ImpactAnalyzer::calculate_impact(&db, &modified_entities))
        } else {
            None
        };

        // 6. Invariant checks
        let mut invariants = Vec::new();
        invariants.push(InvariantCheck {
            invariant_name: "entity_resolution".to_string(),
            passed: !modified_entities.is_empty() || hunks.is_empty(),
            details: format!("Resolved {} semantic entities affected by target", modified_entities.len()),
        });

        let has_affected_tests = impact.as_ref().map(|i| !i.affected_tests.is_empty()).unwrap_or(false);
        invariants.push(InvariantCheck {
            invariant_name: "test_association".to_string(),
            passed: true,
            details: if has_affected_tests {
                "Direct or related test coverage identified for affected entities".to_string()
            } else {
                "No direct test association discovered for this modification surface".to_string()
            },
        });

        // 7. Assemble fact bundle
        Ok(InvestigateFactBundle {
            metadata: BundleMetadata {
                repository_root: repo_path.to_string_lossy().replace('\\', "/"),
                target: target.map(|s| s.to_string()),
                target_kind: target_kind.map(|s| s.to_string()),
                analyzed_at: Utc::now().to_rfc3339(),
                engine_version: env!("CARGO_PKG_VERSION").to_string(),
            },
            entities: modified_entities,
            relationships: Vec::new(),
            impact,
            co_changes,
            entity_histories,
            invariants,
        })
    }

    fn collect_source_files(dir: &Path) -> Vec<PathBuf> {
        let mut files = Vec::new();
        Self::visit_dirs(dir, &mut files);
        files
    }

    fn visit_dirs(dir: &Path, list: &mut Vec<PathBuf>) {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name == ".git" || name == "target" || name == "node_modules" || name == ".gemini" {
                        continue;
                    }
                    Self::visit_dirs(&path, list);
                } else if path.is_file() {
                    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
                    if ext == "rs" || ext == "c" || ext == "h" || ext == "lua" {
                        list.push(path);
                    }
                }
            }
        }
    }
}
