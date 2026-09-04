use oculus_engine::coupling::ChangeCouplingMiner;
use oculus_engine::db::Database;
use oculus_engine::git::GitDiffHunk;
use oculus_engine::impact::ImpactAnalyzer;
use oculus_engine::investigate::Investigator;
use oculus_engine::mapper::GitSemanticMapper;
use oculus_engine::models::{EntityKind, GitCommitRecord, SemanticEntity};
use oculus_engine::parser::AstParser;

#[test]
fn test_lua_parser_entities_and_calls() {
    let lua_code = r#"
local M = {}

local function helper(x)
    return x * 2
end

function M.process(items)
    for _, item in ipairs(items) do
        helper(item)
    end
end

return M
"#;

    let (entities, rels) = AstParser::parse_file("test.lua", lua_code, Some("abc1234"));

    assert!(entities.len() >= 2, "Expected at least 2 functions in test.lua, found {}", entities.len());

    let helper = entities.iter().find(|e| e.name == "helper").expect("helper function not found");
    assert_eq!(helper.kind, EntityKind::Function);
    assert_eq!(helper.file_path, "test.lua");

    let process = entities.iter().find(|e| e.name.contains("process")).expect("process function not found");
    assert_eq!(process.kind, EntityKind::Function);

    // Verify call relationship
    assert!(!rels.is_empty(), "Expected call relationships to be detected");
    assert!(rels.iter().any(|r| r.target_id == "helper" || r.target_id == "ipairs"));
}

#[test]
fn test_rust_parser_entities() {
    let rs_code = r#"
pub struct UserConfig {
    pub name: String,
}

pub fn calculate_total(a: i32, b: i32) -> i32 {
    a + b
}

#[test]
fn test_calculate() {
    let result = calculate_total(2, 3);
    assert_eq!(result, 5);
}
"#;

    let (entities, rels) = AstParser::parse_file("src/lib.rs", rs_code, Some("def5678"));

    let struct_e = entities.iter().find(|e| e.name == "UserConfig").expect("UserConfig not found");
    assert_eq!(struct_e.kind, EntityKind::Type);

    let fn_e = entities.iter().find(|e| e.name == "calculate_total").expect("calculate_total not found");
    assert_eq!(fn_e.kind, EntityKind::Function);

    let test_e = entities.iter().find(|e| e.name == "test_calculate").expect("test_calculate not found");
    assert_eq!(test_e.kind, EntityKind::Test);

    assert!(rels.iter().any(|r| r.target_id == "calculate_total"));
}

#[test]
fn test_git_semantic_mapping() {
    let mut db = Database::in_memory().unwrap();
    let entity = SemanticEntity {
        id: "src/lib.rs:10:compute".to_string(),
        kind: EntityKind::Function,
        name: "compute".to_string(),
        qualified_name: "src/lib.rs::compute".to_string(),
        file_path: "src/lib.rs".to_string(),
        start_line: 10,
        end_line: 25,
        start_col: 1,
        end_col: 2,
        git_oid: Some("commit1".to_string()),
    };
    db.insert_entities(&[entity.clone()]).unwrap();

    let hunk_inside = GitDiffHunk {
        file_path: "src/lib.rs".to_string(),
        old_start: 12,
        old_lines: 3,
        new_start: 12,
        new_lines: 4,
        change_type: "modified".to_string(),
    };

    let mapped = GitSemanticMapper::map_diff_to_entities(&db, "commit1", &[hunk_inside]);
    assert_eq!(mapped.len(), 1);
    assert_eq!(mapped[0].1.name, "compute");

    let hunk_outside = GitDiffHunk {
        file_path: "src/lib.rs".to_string(),
        old_start: 100,
        old_lines: 5,
        new_start: 100,
        new_lines: 5,
        change_type: "modified".to_string(),
    };

    let mapped_outside = GitSemanticMapper::map_diff_to_entities(&db, "commit1", &[hunk_outside]);
    assert_eq!(mapped_outside.len(), 0);
}

#[test]
fn test_change_coupling_mining() {
    let commits = vec![
        GitCommitRecord {
            oid: "c1".to_string(),
            parent_oids: vec![],
            author: "Dev".to_string(),
            timestamp: 100,
            message: "feat 1".to_string(),
            changed_files: vec!["fileA.lua".to_string(), "fileB.lua".to_string()],
        },
        GitCommitRecord {
            oid: "c2".to_string(),
            parent_oids: vec![],
            author: "Dev".to_string(),
            timestamp: 200,
            message: "feat 2".to_string(),
            changed_files: vec!["fileA.lua".to_string(), "fileB.lua".to_string()],
        },
        GitCommitRecord {
            oid: "c3".to_string(),
            parent_oids: vec![],
            author: "Dev".to_string(),
            timestamp: 300,
            message: "fix".to_string(),
            changed_files: vec!["fileA.lua".to_string(), "fileC.lua".to_string()],
        },
    ];

    let couplings = ChangeCouplingMiner::mine_co_changes(&commits, 2, 0.50);
    assert_eq!(couplings.len(), 1);
    assert_eq!(couplings[0].entity_a, "fileA.lua");
    assert_eq!(couplings[0].entity_b, "fileB.lua");
    assert_eq!(couplings[0].co_change_count, 2);
}

#[test]
fn test_impact_analyzer() {
    let mut db = Database::in_memory().unwrap();

    let callee = SemanticEntity {
        id: "src/core.rs:5:callee".to_string(),
        kind: EntityKind::Function,
        name: "callee".to_string(),
        qualified_name: "src/core.rs::callee".to_string(),
        file_path: "src/core.rs".to_string(),
        start_line: 5,
        end_line: 10,
        start_col: 1,
        end_col: 1,
        git_oid: None,
    };

    let caller = SemanticEntity {
        id: "src/api.rs:20:caller".to_string(),
        kind: EntityKind::Function,
        name: "caller".to_string(),
        qualified_name: "src/api.rs::caller".to_string(),
        file_path: "src/api.rs".to_string(),
        start_line: 20,
        end_line: 30,
        start_col: 1,
        end_col: 1,
        git_oid: None,
    };

    let test_fn = SemanticEntity {
        id: "tests/core_test.rs:1:test_fn".to_string(),
        kind: EntityKind::Test,
        name: "test_fn".to_string(),
        qualified_name: "tests/core_test.rs::test_fn".to_string(),
        file_path: "tests/core_test.rs".to_string(),
        start_line: 1,
        end_line: 10,
        start_col: 1,
        end_col: 1,
        git_oid: None,
    };

    db.insert_entities(&[callee.clone(), caller.clone(), test_fn.clone()]).unwrap();

    let rels = vec![
        oculus_engine::models::Relationship {
            source_id: caller.id.clone(),
            target_id: callee.id.clone(),
            kind: oculus_engine::models::RelationKind::Calls,
            confidence: 1.0,
            provenance: oculus_engine::models::Provenance {
                source_type: "ast".to_string(),
                repository_state: Some("HEAD".to_string()),
                confidence: 1.0,
                citations: vec![],
                details: "direct call".to_string(),
            },
        },
        oculus_engine::models::Relationship {
            source_id: test_fn.id.clone(),
            target_id: callee.id.clone(),
            kind: oculus_engine::models::RelationKind::Calls,
            confidence: 1.0,
            provenance: oculus_engine::models::Provenance {
                source_type: "ast".to_string(),
                repository_state: Some("HEAD".to_string()),
                confidence: 1.0,
                citations: vec![],
                details: "direct test call".to_string(),
            },
        },
    ];
    db.insert_relationships(&rels).unwrap();

    let impact = ImpactAnalyzer::calculate_impact(&db, &[callee]);
    assert_eq!(impact.direct_callers.len(), 1);
    assert_eq!(impact.direct_callers[0].name, "caller");
    assert_eq!(impact.affected_tests.len(), 1);
    assert_eq!(impact.affected_tests[0].name, "test_fn");
    assert!(impact.affected_files.contains(&"src/api.rs".to_string()));
    assert!(impact.affected_files.contains(&"tests/core_test.rs".to_string()));
}

#[test]
fn test_investigator_current_repo() {
    let bundle = Investigator::run_investigation(".", None, None, None, None).expect("investigation failed");
    assert!(!bundle.metadata.repository_root.is_empty());
    assert!(!bundle.metadata.engine_version.is_empty());
    assert!(!bundle.co_changes.is_empty());
    assert!(!bundle.invariants.is_empty());
    assert!(!bundle.relationships.is_empty(), "expected relationships with provenance to be populated");
    assert!(bundle.relationships.iter().all(|r| !r.provenance.source_type.is_empty() && r.confidence > 0.0));
}

#[test]
fn test_forge_traceability_linking() {
    let mut db = Database::in_memory().unwrap();
    let entity = SemanticEntity {
        id: "src/parser.rs:50:parse_tokens".to_string(),
        kind: EntityKind::Function,
        name: "parse_tokens".to_string(),
        qualified_name: "src/parser.rs::parse_tokens".to_string(),
        file_path: "src/parser.rs".to_string(),
        start_line: 50,
        end_line: 80,
        start_col: 1,
        end_col: 2,
        git_oid: None,
    };
    db.insert_entities(&[entity]).unwrap();

    let artifact = oculus_engine::models::ForgeArtifact {
        forge: "github".to_string(),
        kind: "issue".to_string(),
        id: "42".to_string(),
        title: Some("Crash when calling `parse_tokens` with empty input".to_string()),
        body: Some("Encountered unexpected panic in parser.rs while processing empty string".to_string()),
        author: Some("developer".to_string()),
        state: Some("open".to_string()),
        url: Some("https://github.com/org/repo/issues/42".to_string()),
        labels: vec!["bug".to_string()],
        comments: vec![
            oculus_engine::models::ForgeComment {
                author: "maintainer".to_string(),
                body: "Reproduced in `parse_tokens`. Line 60 lacks an empty check.".to_string(),
                created_at: None,
            },
        ],
    };

    let links = oculus_engine::forge::ForgeTraceabilityLinker::link_artifact_to_code(&db, &artifact);
    assert_eq!(links.len(), 1);
    assert_eq!(links[0].target_entity.name, "parse_tokens");
    assert!(links[0].confidence >= 0.90);
    assert!(!links[0].evidence.is_empty());
}
