use std::collections::HashSet;
use crate::db::Database;
use crate::models::{EntityKind, SemanticEntity, StructuralImpact};

pub struct ImpactAnalyzer;

impl ImpactAnalyzer {
    pub fn calculate_impact(
        db: &Database,
        modified_entities: &[SemanticEntity],
    ) -> StructuralImpact {
        let mut affected_files_set = HashSet::new();
        let mut direct_callers_map = HashSet::new();
        let mut affected_tests_map = HashSet::new();
        let mut callers = Vec::new();
        let mut tests = Vec::new();

        for m in modified_entities {
            affected_files_set.insert(m.file_path.clone());

            if let Ok(c_list) = db.get_callers(&m.id) {
                for caller in c_list {
                    if caller.kind == EntityKind::Test || caller.file_path.contains("test") || caller.file_path.contains("spec") {
                        if affected_tests_map.insert(caller.id.clone()) {
                            affected_files_set.insert(caller.file_path.clone());
                            tests.push(caller);
                        }
                    } else if direct_callers_map.insert(caller.id.clone()) {
                        affected_files_set.insert(caller.file_path.clone());
                        callers.push(caller);
                    }
                }
            }
        }

        // Also check if any modified entity itself is a test
        for m in modified_entities {
            if (m.kind == EntityKind::Test || m.file_path.contains("test") || m.file_path.contains("spec"))
                && affected_tests_map.insert(m.id.clone())
            {
                tests.push(m.clone());
            }
        }

        let propagation_depth = if !callers.is_empty() { 2 } else if !modified_entities.is_empty() { 1 } else { 0 };

        StructuralImpact {
            modified_entities: modified_entities.to_vec(),
            direct_callers: callers,
            affected_tests: tests,
            affected_files: affected_files_set.into_iter().collect(),
            propagation_depth,
        }
    }
}
