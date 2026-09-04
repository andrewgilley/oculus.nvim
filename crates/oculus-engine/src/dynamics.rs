use std::collections::HashSet;
use crate::db::Database;
use crate::models::{
    ArchitecturalDynamics, BoundaryCrossing, CoChangeRelationship, EntityHistory,
    HistoricalPrecedent, SemanticEntity, StructuralImpact, SubsystemInstability,
};

pub struct ArchitecturalDynamicsAnalyzer;

impl ArchitecturalDynamicsAnalyzer {
    pub fn analyze(
        db: &Database,
        modified_entities: &[SemanticEntity],
        impact: Option<&StructuralImpact>,
        histories: &[EntityHistory],
        co_changes: &[CoChangeRelationship],
        exclude_oid: Option<&str>,
    ) -> ArchitecturalDynamics {
        let boundary_crossings = Self::detect_boundary_crossings(modified_entities, impact);
        let subsystem_instabilities = Self::detect_subsystem_instabilities(
            modified_entities,
            impact,
            histories,
            co_changes,
        );
        let historical_precedents = Self::find_historical_precedents(
            db,
            modified_entities,
            exclude_oid,
            6,
        );

        ArchitecturalDynamics {
            boundary_crossings,
            subsystem_instabilities,
            historical_precedents,
        }
    }

    pub fn resolve_subsystem(file_path: &str) -> String {
        let norm = file_path.replace('\\', "/");
        let parts: Vec<&str> = norm.split('/').collect();

        if norm.starts_with("crates/") && parts.len() >= 4 && parts[2] == "src" {
            let crate_name = parts[1];
            let mod_file = parts[3].trim_end_matches(".rs");
            format!("{}::{}", crate_name, mod_file)
        } else if norm.starts_with("crates/") && parts.len() >= 2 {
            format!("crate:{}", parts[1])
        } else if norm.starts_with("lua/oculus/") {
            if parts.len() >= 4 {
                let sub = parts[2];
                let file = parts[3].trim_end_matches(".lua");
                format!("oculus::{}::{}", sub, file)
            } else if parts.len() == 3 {
                let file = parts[2].trim_end_matches(".lua");
                format!("oculus::{}", file)
            } else {
                "oculus::core".to_string()
            }
        } else if norm.starts_with("tests/") {
            "test_suite".to_string()
        } else if parts.len() >= 2 {
            format!("{}/{}", parts[0], parts[1])
        } else {
            parts.first().unwrap_or(&"root").to_string()
        }
    }

    pub fn detect_boundary_crossings(
        modified_entities: &[SemanticEntity],
        impact: Option<&StructuralImpact>,
    ) -> Vec<BoundaryCrossing> {
        let mut crossings = Vec::new();
        let mut seen_pairs = HashSet::new();

        // 1. Crossings between modified entities (multi-subsystem changes)
        let mut modified_subsystems: HashSet<String> = HashSet::new();
        for e in modified_entities {
            let sub = Self::resolve_subsystem(&e.file_path);
            modified_subsystems.insert(sub);
        }

        if modified_subsystems.len() > 1 {
            let subs: Vec<String> = modified_subsystems.into_iter().collect();
            crossings.push(BoundaryCrossing {
                source_subsystem: subs[0].clone(),
                target_subsystem: subs[1..].join(", "),
                boundary_kind: "multi_subsystem_modification".to_string(),
                entities_involved: modified_entities.iter().map(|e| e.name.clone()).take(5).collect(),
                risk_level: if subs.len() > 2 { "high".to_string() } else { "medium".to_string() },
                details: format!(
                    "Changeset spans {} architectural boundaries across {} subsystems",
                    subs.len(),
                    subs.join(" ↔ ")
                ),
            });
        }

        // 2. Caller boundary crossings
        if let Some(imp) = impact {
            for caller in &imp.direct_callers {
                let caller_sub = Self::resolve_subsystem(&caller.file_path);
                for target in modified_entities {
                    let target_sub = Self::resolve_subsystem(&target.file_path);
                    if caller_sub != target_sub && seen_pairs.insert((caller_sub.clone(), target_sub.clone())) {
                        crossings.push(BoundaryCrossing {
                            source_subsystem: caller_sub.clone(),
                            target_subsystem: target_sub.clone(),
                            boundary_kind: "inter_subsystem_call".to_string(),
                            entities_involved: vec![caller.name.clone(), target.name.clone()],
                            risk_level: "medium".to_string(),
                            details: format!(
                                "Caller `{}` in subsystem `{}` invokes `{}` in subsystem `{}`",
                                caller.name, caller_sub, target.name, target_sub
                            ),
                        });
                    }
                }
            }
        }

        crossings
    }

    pub fn detect_subsystem_instabilities(
        modified_entities: &[SemanticEntity],
        impact: Option<&StructuralImpact>,
        histories: &[EntityHistory],
        co_changes: &[CoChangeRelationship],
    ) -> Vec<SubsystemInstability> {
        let mut alerts = Vec::new();
        let mut seen = HashSet::new();

        let test_entities: HashSet<&str> = impact
            .map(|i| i.affected_tests.iter().map(|t| t.name.as_str()).collect())
            .unwrap_or_default();

        for e in modified_entities {
            let sub = Self::resolve_subsystem(&e.file_path);
            let hist = histories.iter().find(|h| h.entity_id == e.id || h.qualified_name == e.qualified_name);

            if let Some(h) = hist {
                // Anomaly 1: High Churn with No Dedicated Test
                let has_test = test_entities.contains(e.name.as_str())
                    || impact.map(|i| i.affected_files.iter().any(|f| f.contains("test"))).unwrap_or(false);

                if h.total_commits >= 2 && !has_test && seen.insert((e.id.clone(), "high_churn_untested")) {
                    alerts.push(SubsystemInstability {
                        subsystem: sub.clone(),
                        entity_name: e.name.clone(),
                        instability_score: (h.total_commits as f64) * 1.5,
                        risk_category: "high_churn_untested".to_string(),
                        details: format!(
                            "Hot-spot symbol `{}` has {} historical revisions but lacks direct test coverage in local call graph",
                            e.name, h.total_commits
                        ),
                    });
                }

                // Anomaly 2: Single Maintainer Bottleneck (Bus Factor = 1 on high-churn code)
                if h.total_commits >= 3 && h.authors.len() == 1 && seen.insert((e.id.clone(), "single_maintainer_bottleneck")) {
                    alerts.push(SubsystemInstability {
                        subsystem: sub.clone(),
                        entity_name: e.name.clone(),
                        instability_score: 3.5,
                        risk_category: "single_maintainer_bottleneck".to_string(),
                        details: format!(
                            "Bus factor vulnerability: symbol `{}` has 100% of revisions authored solely by @{}",
                            e.name, h.authors[0]
                        ),
                    });
                }
            }

            // Anomaly 3: Architectural Coupling Hub
            let coupled_count = co_changes
                .iter()
                .filter(|c| c.entity_a == e.file_path || c.entity_b == e.file_path || c.entity_a.contains(&e.name) || c.entity_b.contains(&e.name))
                .count();

            if coupled_count >= 2 && seen.insert((e.id.clone(), "coupling_hub")) {
                alerts.push(SubsystemInstability {
                    subsystem: sub.clone(),
                    entity_name: e.name.clone(),
                    instability_score: 4.0,
                    risk_category: "coupling_hub".to_string(),
                    details: format!(
                        "Architectural ripple risk: modifying `{}` historically co-changes with {} other entities",
                        e.name, coupled_count
                    ),
                });
            }
        }

        alerts.sort_by(|a, b| b.instability_score.partial_cmp(&a.instability_score).unwrap_or(std::cmp::Ordering::Equal));
        alerts
    }

    pub fn find_historical_precedents(
        db: &Database,
        modified_entities: &[SemanticEntity],
        exclude_oid: Option<&str>,
        limit: usize,
    ) -> Vec<HistoricalPrecedent> {
        let mut precedents = Vec::new();
        let mut seen_oids = HashSet::new();

        let files: Vec<String> = modified_entities
            .iter()
            .map(|e| e.file_path.clone())
            .collect();

        if files.is_empty() {
            return precedents;
        }

        if let Ok(commits) = db.get_commits_touching_files(&files, exclude_oid, limit * 2) {
            for c in commits {
                if seen_oids.insert(c.oid.clone()) {
                    let mut relevant = Vec::new();
                    for e in modified_entities {
                        if c.changed_files.iter().any(|cf| cf.ends_with(&e.file_path) || e.file_path.ends_with(cf)) {
                            relevant.push(e.name.clone());
                        }
                    }

                    let reason = if !relevant.is_empty() {
                        format!("Modified {} in {}", relevant.join(", "), c.oid.chars().take(7).collect::<String>())
                    } else {
                        format!("Changed file related to investigation target")
                    };

                    precedents.push(HistoricalPrecedent {
                        commit_oid: c.oid,
                        author: c.author,
                        timestamp: c.timestamp,
                        message: c.message.lines().next().unwrap_or("").to_string(),
                        relevant_entities: relevant,
                        relevance_reason: reason,
                    });

                    if precedents.len() >= limit {
                        break;
                    }
                }
            }
        }

        precedents
    }
}
