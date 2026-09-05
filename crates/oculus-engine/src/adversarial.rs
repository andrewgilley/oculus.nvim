use crate::models::{
    AgentClaim, AgentHypothesis, ClaimVerification, ConnectedAction, DerivedInvestigation,
    SemanticEntity, StructuralImpact, VerificationStatus,
    ArchitecturalDynamics, CoChangeRelationship, InvariantCheck,
};

pub struct AdversarialRealityChecker;

impl AdversarialRealityChecker {
    pub fn verify_claims(
        claims: &[AgentClaim],
        entities: &[SemanticEntity],
        impact: Option<&StructuralImpact>,
        dynamics: Option<&ArchitecturalDynamics>,
        co_changes: &[CoChangeRelationship],
    ) -> Vec<ClaimVerification> {
        let mut verifications = Vec::new();

        for claim in claims {
            let (status, confidence, evidence, details) = match claim.claim_type.as_str() {
                "no_external_callers" | "isolated_symbol" => {
                    let subject_is_modified = entities.iter().any(|e| {
                        e.name == claim.subject || e.qualified_name.contains(&claim.subject)
                    });

                    let callers: Vec<_> = if let Some(imp) = impact {
                        if subject_is_modified {
                            imp.direct_callers.iter().collect()
                        } else {
                            imp.direct_callers
                                .iter()
                                .filter(|c| c.name.contains(&claim.subject) || c.qualified_name.contains(&claim.subject))
                                .collect()
                        }
                    } else {
                        Vec::new()
                    };

                    if callers.is_empty() {
                        (
                            VerificationStatus::Confirmed,
                            1.0,
                            vec!["AST call graph search across all indexed files yielded 0 callers".to_string()],
                            format!("Confirmed: Subject `{}` has 0 direct external callers.", claim.subject),
                        )
                    } else {
                        let cites: Vec<String> = callers
                            .iter()
                            .map(|c| format!("caller `{}` in {}:{}", c.name, c.file_path, c.start_line))
                            .collect();
                        (
                            VerificationStatus::Refuted,
                            1.0,
                            cites.clone(),
                            format!("Refuted: Subject `{}` has {} direct caller(s): {}", claim.subject, callers.len(), cites.join("; ")),
                        )
                    }
                }
                "subsystem_confined" | "no_boundary_crossings" => {
                    let crossings: Vec<_> = dynamics
                        .map(|d| {
                            d.boundary_crossings
                                .iter()
                                .filter(|bc| {
                                    bc.source_subsystem.contains(&claim.subject)
                                        || bc.target_subsystem.contains(&claim.subject)
                                        || bc.entities_involved.iter().any(|e| e.contains(&claim.subject))
                                })
                                .collect()
                        })
                        .unwrap_or_default();

                    if crossings.is_empty() {
                        (
                            VerificationStatus::Confirmed,
                            0.95,
                            vec!["Boundary analyzer detected zero boundary crossings involving subject".to_string()],
                            format!("Confirmed: Subject `{}` is architecturally confined without detected boundary leakage.", claim.subject),
                        )
                    } else {
                        let cites: Vec<String> = crossings
                            .iter()
                            .map(|bc| format!("{} -> {} ({})", bc.source_subsystem, bc.target_subsystem, bc.details))
                            .collect();
                        (
                            VerificationStatus::Refuted,
                            1.0,
                            cites.clone(),
                            format!("Refuted: Detected {} boundary crossing(s): {}", crossings.len(), cites.join("; ")),
                        )
                    }
                }
                "has_test_coverage" => {
                    let subject_is_modified = entities.iter().any(|e| {
                        e.name == claim.subject || e.qualified_name.contains(&claim.subject)
                    });

                    let tests: Vec<_> = if let Some(imp) = impact {
                        if subject_is_modified {
                            imp.affected_tests.iter().collect()
                        } else {
                            imp.affected_tests
                                .iter()
                                .filter(|t| t.file_path.contains(&claim.subject) || t.name.contains(&claim.subject))
                                .collect()
                        }
                    } else {
                        Vec::new()
                    };

                    if !tests.is_empty() {
                        let cites: Vec<String> = tests
                            .iter()
                            .map(|t| format!("test `{}` in {}:{}", t.name, t.file_path, t.start_line))
                            .collect();
                        (
                            VerificationStatus::Confirmed,
                            0.90,
                            cites.clone(),
                            format!("Confirmed: Subject `{}` is exercised by {} test(s): {}", claim.subject, tests.len(), cites.join("; ")),
                        )
                    } else {
                        (
                            VerificationStatus::Refuted,
                            0.95,
                            vec!["Impact test detector found 0 associated test suites".to_string()],
                            format!("Refuted: No automated tests found exercising subject `{}`.", claim.subject),
                        )
                    }
                }
                "untested_entity" => {
                    let subject_is_modified = entities.iter().any(|e| {
                        e.name == claim.subject || e.qualified_name.contains(&claim.subject)
                    });

                    let tests: Vec<_> = if let Some(imp) = impact {
                        if subject_is_modified {
                            imp.affected_tests.iter().collect()
                        } else {
                            imp.affected_tests
                                .iter()
                                .filter(|t| t.file_path.contains(&claim.subject) || t.name.contains(&claim.subject))
                                .collect()
                        }
                    } else {
                        Vec::new()
                    };

                    if tests.is_empty() {
                        (
                            VerificationStatus::Confirmed,
                            0.95,
                            vec!["No tests detected in test suites for entity".to_string()],
                            format!("Confirmed: Subject `{}` currently lacks automated test coverage.", claim.subject),
                        )
                    } else {
                        let cites: Vec<String> = tests
                            .iter()
                            .map(|t| format!("test `{}` in {}:{}", t.name, t.file_path, t.start_line))
                            .collect();
                        (
                            VerificationStatus::Refuted,
                            0.95,
                            cites.clone(),
                            format!("Refuted: Subject `{}` has active test coverage: {}", claim.subject, cites.join("; ")),
                        )
                    }
                }
                "co_changes_with" => {
                    let target_subj = claim.target.as_deref().unwrap_or("");
                    let found = co_changes.iter().find(|cc| {
                        (cc.entity_a.contains(&claim.subject) && cc.entity_b.contains(target_subj))
                            || (cc.entity_b.contains(&claim.subject) && cc.entity_a.contains(target_subj))
                    });

                    if let Some(cc) = found {
                        (
                            VerificationStatus::Confirmed,
                            cc.confidence,
                            cc.sample_commits.iter().map(|c| format!("commit:{}", c)).collect(),
                            format!("Confirmed: `{}` and `{}` co-change (confidence {:.0}%, {} historical commits)", claim.subject, target_subj, cc.confidence * 100.0, cc.co_change_count),
                        )
                    } else {
                        (
                            VerificationStatus::Refuted,
                            0.80,
                            vec!["Jaccard co-change miner found 0 statistical co-occurrences".to_string()],
                            format!("Refuted: No statistical co-change relationship between `{}` and `{}` in history.", claim.subject, target_subj),
                        )
                    }
                }
                _ => {
                    (
                        VerificationStatus::Inconclusive,
                        0.5,
                        vec!["Claim type not recognized for deterministic verification".to_string()],
                        format!("Inconclusive: Unable to deterministically verify claim type `{}`.", claim.claim_type),
                    )
                }
            };

            verifications.push(ClaimVerification {
                claim_id: claim.claim_id.clone(),
                claim_type: claim.claim_type.clone(),
                assertion: claim.assertion.clone(),
                status,
                confidence,
                deterministic_evidence: evidence,
                details,
            });
        }

        verifications
    }

    pub fn synthesize_derived_investigation(
        entities: &[SemanticEntity],
        impact: Option<&StructuralImpact>,
        dynamics: Option<&ArchitecturalDynamics>,
        co_changes: &[CoChangeRelationship],
        _invariants: &[InvariantCheck],
    ) -> DerivedInvestigation {
        let mut hypotheses = Vec::new();
        let mut unanswered_questions = Vec::new();
        let mut candidate_patches = Vec::new();

        let callers_count = impact.map(|i| i.direct_callers.len()).unwrap_or(0);
        let crossings = dynamics.map(|d| d.boundary_crossings.as_slice()).unwrap_or(&[]);

        // 1. Caller Blast Radius Hypothesis
        if !entities.is_empty() {
            let primary_entity = &entities[0];
            let claim = AgentClaim {
                claim_id: "claim_blast_radius".to_string(),
                claim_type: if callers_count == 0 { "no_external_callers".to_string() } else { "isolated_symbol".to_string() },
                subject: primary_entity.name.clone(),
                target: None,
                assertion: if callers_count == 0 {
                    format!("`{}` has no external callers; change blast radius is contained", primary_entity.name)
                } else {
                    format!("`{}` is an internal helper with 0 downstream callers", primary_entity.name)
                },
            };

            let verifs = Self::verify_claims(&[claim.clone()], entities, impact, dynamics, co_changes);
            let is_confirmed = verifs.first().map(|v| v.status == VerificationStatus::Confirmed).unwrap_or(false);

            let mut actions = Vec::new();
            if callers_count > 0 {
                actions.push(ConnectedAction {
                    action_type: "test_generation".to_string(),
                    label: "Generate Caller Invariant Tests".to_string(),
                    description: format!("Draft invariant unit tests protecting {} caller(s) of `{}`", callers_count, primary_entity.name),
                    target: Some(primary_entity.name.clone()),
                    command_hint: Some(":OculusInvestigateTestScaffold".to_string()),
                });
                unanswered_questions.push(format!("Do the {} callers of `{}` handle updated return invariants or edge conditions?", callers_count, primary_entity.name));
            }

            hypotheses.push(AgentHypothesis {
                id: "hyp_blast_radius".to_string(),
                title: if is_confirmed { "Localized Blast Radius: Symbol is Structurally Isolated".to_string() } else { "Expanded Blast Radius: Modifies Actively Invoked Symbol".to_string() },
                rationale: format!("Syntactic call graph analysis checked all callers for `{}` across the repository.", primary_entity.name),
                confidence: if is_confirmed { 0.95 } else { 0.90 },
                claims: vec![claim],
                verifications: verifs,
                suggested_actions: actions,
            });
        }

        // 2. Architectural Boundary Containment Hypothesis
        if !crossings.is_empty() {
            let first_cross = &crossings[0];
            let claim = AgentClaim {
                claim_id: "claim_boundary_containment".to_string(),
                claim_type: "subsystem_confined".to_string(),
                subject: first_cross.source_subsystem.clone(),
                target: Some(first_cross.target_subsystem.clone()),
                assertion: format!("Changes are strictly confined to `{}` without crossing into `{}`", first_cross.source_subsystem, first_cross.target_subsystem),
            };

            let verifs = Self::verify_claims(&[claim.clone()], entities, impact, dynamics, co_changes);

            hypotheses.push(AgentHypothesis {
                id: "hyp_boundary_leakage".to_string(),
                title: "Architectural Leakage: Cross-Subsystem Coupling Detected".to_string(),
                rationale: format!("Boundary analysis detected cross-subsystem invocation between `{}` and `{}`.", first_cross.source_subsystem, first_cross.target_subsystem),
                confidence: 0.92,
                claims: vec![claim],
                verifications: verifs,
                suggested_actions: vec![
                    ConnectedAction {
                        action_type: "decouple_refactor".to_string(),
                        label: "Plan Subsystem Decoupling Refactor".to_string(),
                        description: format!("Introduce an abstraction facade between `{}` and `{}`", first_cross.source_subsystem, first_cross.target_subsystem),
                        target: Some(format!("{} ➔ {}", first_cross.source_subsystem, first_cross.target_subsystem)),
                        command_hint: Some(":OculusInvestigateRefactorPlan".to_string()),
                    },
                ],
            });

            unanswered_questions.push(format!("Can dependency `{}` ➔ `{}` be inverted or routed through an event bus to preserve module boundaries?", first_cross.source_subsystem, first_cross.target_subsystem));
        }

        // 3. Test Coverage & Regression Safety Hypothesis
        if !entities.is_empty() {
            let primary = &entities[0];
            let claim = AgentClaim {
                claim_id: "claim_test_coverage".to_string(),
                claim_type: "has_test_coverage".to_string(),
                subject: primary.name.clone(),
                target: None,
                assertion: format!("`{}` has automated regression test coverage", primary.name),
            };

            let verifs = Self::verify_claims(&[claim.clone()], entities, impact, dynamics, co_changes);
            let has_tests = verifs.first().map(|v| v.status == VerificationStatus::Confirmed).unwrap_or(false);

            hypotheses.push(AgentHypothesis {
                id: "hyp_test_safety".to_string(),
                title: if has_tests { "Regression Guarded: Test Suite Covers Modified Entities".to_string() } else { "Regression Risk: Modified Entities Lack Automated Coverage".to_string() },
                rationale: format!("Checked test discovery suites for symbols matching `{}`.", primary.name),
                confidence: 0.88,
                claims: vec![claim],
                verifications: verifs,
                suggested_actions: if !has_tests {
                    vec![ConnectedAction {
                        action_type: "test_generation".to_string(),
                        label: "Generate Regression Test Scaffold".to_string(),
                        description: format!("Create test file and test cases covering `{}`", primary.name),
                        target: Some(primary.file_path.clone()),
                        command_hint: Some(":OculusInvestigateTestScaffold".to_string()),
                    }]
                } else {
                    Vec::new()
                },
            });

            if !has_tests {
                candidate_patches.push(format!("Add unit tests targeting `{}` in `{}`", primary.name, primary.file_path));
            }
        }

        // 4. Overall Adversarial Verdict
        let confirmed_count: usize = hypotheses
            .iter()
            .flat_map(|h| h.verifications.iter())
            .filter(|v| v.status == VerificationStatus::Confirmed)
            .count();
        let refuted_count: usize = hypotheses
            .iter()
            .flat_map(|h| h.verifications.iter())
            .filter(|v| v.status == VerificationStatus::Refuted)
            .count();

        let verdict = if refuted_count > 0 && confirmed_count > 0 {
            "PARTIALLY_VERIFIED".to_string()
        } else if refuted_count > 0 {
            "CLAIMS_REFUTED".to_string()
        } else if confirmed_count > 0 {
            "ALL_CLAIMS_VERIFIED".to_string()
        } else {
            "INCONCLUSIVE".to_string()
        };

        DerivedInvestigation {
            hypotheses,
            unanswered_questions,
            candidate_patches,
            adversarial_verdict: verdict,
        }
    }
}
