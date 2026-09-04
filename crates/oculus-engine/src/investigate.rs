use std::fs;
use std::path::{Path, PathBuf};
use chrono::Utc;

use crate::coupling::ChangeCouplingMiner;
use crate::db::Database;
use crate::forge::ForgeTraceabilityLinker;
use crate::git::GitReader;
use crate::impact::ImpactAnalyzer;
use crate::mapper::GitSemanticMapper;
use crate::models::{
    BundleMetadata, EntityHistory, ForgeArtifact, InvariantCheck, InvestigateFactBundle,
    Provenance, RelationKind, Relationship, SemanticEntity,
};
use crate::parser::AstParser;

pub struct Investigator;

impl Investigator {
    pub fn run_investigation<P: AsRef<Path>>(
        repo_root: P,
        target: Option<&str>,
        target_kind: Option<&str>,
        db_path: Option<&Path>,
        forge_artifact: Option<ForgeArtifact>,
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
        let is_issue_target = target_kind == Some("issue")
            || target.map(|t| t.starts_with("http") || t.starts_with('#') || t.contains("/issues/")).unwrap_or(false);

        let hunks = if is_issue_target {
            let uncommitted = GitReader::uncommitted_diff_hunks(repo_path);
            if !uncommitted.is_empty() {
                uncommitted
            } else {
                Vec::new()
            }
        } else {
            match target {
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
            }
        };

        // 4. Map diff hunks to semantic entities
        let target_oid = if is_issue_target {
            head_oid.as_deref().unwrap_or("HEAD")
        } else {
            target.unwrap_or(head_oid.as_deref().unwrap_or("HEAD"))
        };
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

        // 5. Traceability linking with Forge Artifact if provided
        let mut traceability_links = Vec::new();
        if let Some(ref artifact) = forge_artifact {
            traceability_links = ForgeTraceabilityLinker::link_artifact_to_code(&db, artifact);
            // If no direct Git diff entities were found (e.g. an unpatched Issue),
            // candidate implementation entities are seeded from traceability links
            if modified_entities.is_empty() {
                for link in &traceability_links {
                    if link.confidence >= 0.80 && !modified_entities.iter().any(|e| e.id == link.target_entity.id) {
                        if let Ok(history) = db.get_entity_history(&link.target_entity.id) {
                            entity_histories.push(history);
                        }
                        modified_entities.push(link.target_entity.clone());
                    }
                }
            }
        }

        // 6. Calculate structural impact (propagation surface)
        let impact = if !modified_entities.is_empty() {
            Some(ImpactAnalyzer::calculate_impact(&db, &modified_entities))
        } else {
            None
        };

        // 7. Invariant checks
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

        if let Some(ref artifact) = forge_artifact {
            invariants.push(InvariantCheck {
                invariant_name: "forge_traceability".to_string(),
                passed: !traceability_links.is_empty(),
                details: format!(
                    "Linked {} implementation entities to forge artifact {}:{}",
                    traceability_links.len(),
                    artifact.kind,
                    artifact.id
                ),
            });
        }

        // 8. Assemble unified Evidence Graph relationships with mandatory provenance
        let mut relationships: Vec<Relationship> = Vec::new();

        // 8a. Forge Traceability Links -> Relationship
        if let Some(ref artifact) = forge_artifact {
            for link in &traceability_links {
                relationships.push(Relationship {
                    source_id: format!("{}:{}", artifact.kind, artifact.id),
                    target_id: link.target_entity.id.clone(),
                    kind: RelationKind::References,
                    confidence: link.confidence,
                    provenance: Provenance {
                        source_type: "forge".to_string(),
                        repository_state: Some(format!("{}:{}", artifact.kind, artifact.id)),
                        confidence: link.confidence,
                        citations: link.evidence.clone(),
                        details: link.match_reason.clone(),
                    },
                });
            }
        }

        // 8b. Git Diff modifications -> Relationship
        for entity in &modified_entities {
            relationships.push(Relationship {
                source_id: target_oid.to_string(),
                target_id: entity.id.clone(),
                kind: RelationKind::ModifiedBy,
                confidence: 1.0,
                provenance: Provenance {
                    source_type: "git_diff".to_string(),
                    repository_state: Some(target_oid.to_string()),
                    confidence: 1.0,
                    citations: vec![format!("{}:{}-{}", entity.file_path, entity.start_line, entity.end_line)],
                    details: format!("Git diff hunk intersects AST node of {} ({:?})", entity.name, entity.kind),
                },
            });
        }

        // 8c. Callers & Tests -> Relationship
        if let Some(ref imp) = impact {
            for caller in &imp.direct_callers {
                for target_e in &modified_entities {
                    relationships.push(Relationship {
                        source_id: caller.id.clone(),
                        target_id: target_e.id.clone(),
                        kind: RelationKind::Calls,
                        confidence: 0.95,
                        provenance: Provenance {
                            source_type: "ast".to_string(),
                            repository_state: head_oid.as_deref().map(|s| s.to_string()),
                            confidence: 0.95,
                            citations: vec![format!("{}:{}", caller.file_path, caller.start_line)],
                            details: format!("Caller `{}` in `{}` calls `{}`", caller.name, caller.file_path, target_e.name),
                        },
                    });
                }
            }

            for test in &imp.affected_tests {
                for target_e in &modified_entities {
                    relationships.push(Relationship {
                        source_id: test.id.clone(),
                        target_id: target_e.id.clone(),
                        kind: RelationKind::TestedBy,
                        confidence: 0.90,
                        provenance: Provenance {
                            source_type: "test_association".to_string(),
                            repository_state: head_oid.as_deref().map(|s| s.to_string()),
                            confidence: 0.90,
                            citations: vec![format!("{}:{}", test.file_path, test.start_line)],
                            details: format!("Test entity `{}` in `{}` exercises `{}`", test.name, test.file_path, target_e.name),
                        },
                    });
                }
            }
        }

        // 8d. Co-Changes -> Relationship
        for co in &co_changes {
            relationships.push(Relationship {
                source_id: co.entity_a.clone(),
                target_id: co.entity_b.clone(),
                kind: RelationKind::CoChangesWith,
                confidence: co.confidence,
                provenance: Provenance {
                    source_type: "git_history".to_string(),
                    repository_state: head_oid.as_deref().map(|s| s.to_string()),
                    confidence: co.confidence,
                    citations: co.sample_commits.iter().map(|c| format!("commit:{}", c)).collect(),
                    details: format!("Statistical co-change (Jaccard: {:.2}) across {} commits", co.confidence, co.co_change_count),
                },
            });
        }

        // 9. Assemble fact bundle
        Ok(InvestigateFactBundle {
            metadata: BundleMetadata {
                repository_root: repo_path.to_string_lossy().replace('\\', "/"),
                target: target.map(|s| s.to_string()),
                target_kind: target_kind.map(|s| s.to_string()),
                analyzed_at: Utc::now().to_rfc3339(),
                engine_version: env!("CARGO_PKG_VERSION").to_string(),
            },
            entities: modified_entities,
            relationships,
            impact,
            co_changes,
            entity_histories,
            invariants,
            forge_artifact,
            traceability_links,
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
