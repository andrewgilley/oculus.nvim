use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityKind {
    Module,
    Namespace,
    Type,
    Function,
    Method,
    Trait,
    Interface,
    Constant,
    Test,
    File,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SemanticEntity {
    pub id: String,
    pub kind: EntityKind,
    pub name: String,
    pub qualified_name: String,
    pub file_path: String,
    pub start_line: usize,
    pub end_line: usize,
    pub start_col: usize,
    pub end_col: usize,
    pub git_oid: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelationKind {
    Calls,
    CalledBy,
    Defines,
    Imports,
    Implements,
    References,
    CoChangesWith,
    TestedBy,
    ModifiedBy,
    PrecedentFor,
    CrossesBoundary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Provenance {
    pub source_type: String,
    #[serde(default)]
    pub repository_state: Option<String>,
    #[serde(default)]
    pub confidence: f64,
    pub citations: Vec<String>,
    pub details: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Relationship {
    pub source_id: String,
    pub target_id: String,
    pub kind: RelationKind,
    pub confidence: f64,
    pub provenance: Provenance,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitCommitRecord {
    pub oid: String,
    pub parent_oids: Vec<String>,
    pub author: String,
    pub timestamp: i64,
    pub message: String,
    pub changed_files: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntityChangeRecord {
    pub commit_oid: String,
    pub entity_id: String,
    pub file_path: String,
    pub change_kind: String,
    pub old_line_range: Option<(usize, usize)>,
    pub new_line_range: Option<(usize, usize)>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoChangeRelationship {
    pub entity_a: String,
    pub entity_b: String,
    pub co_change_count: usize,
    pub confidence: f64,
    pub sample_commits: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StructuralImpact {
    pub modified_entities: Vec<SemanticEntity>,
    pub direct_callers: Vec<SemanticEntity>,
    pub affected_tests: Vec<SemanticEntity>,
    pub affected_files: Vec<String>,
    pub propagation_depth: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntityHistory {
    pub entity_id: String,
    pub qualified_name: String,
    pub introduction_commit: Option<String>,
    pub total_commits: usize,
    pub authors: Vec<String>,
    pub last_modified: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InvariantCheck {
    pub invariant_name: String,
    pub passed: bool,
    pub details: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForgeComment {
    pub author: String,
    pub body: String,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForgeArtifact {
    pub forge: String,
    pub kind: String,
    pub id: String,
    pub title: Option<String>,
    pub body: Option<String>,
    pub author: Option<String>,
    pub state: Option<String>,
    pub url: Option<String>,
    pub labels: Vec<String>,
    pub comments: Vec<ForgeComment>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceabilityLink {
    pub forge_item: String,
    pub target_entity: SemanticEntity,
    pub confidence: f64,
    pub match_reason: String,
    pub evidence: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleMetadata {
    pub repository_root: String,
    pub target: Option<String>,
    pub target_kind: Option<String>,
    pub analyzed_at: String,
    pub engine_version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BoundaryCrossing {
    pub source_subsystem: String,
    pub target_subsystem: String,
    pub boundary_kind: String,
    pub entities_involved: Vec<String>,
    pub risk_level: String,
    pub details: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubsystemInstability {
    pub subsystem: String,
    pub entity_name: String,
    pub instability_score: f64,
    pub risk_category: String,
    pub details: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoricalPrecedent {
    pub commit_oid: String,
    pub author: String,
    pub timestamp: i64,
    pub message: String,
    pub relevant_entities: Vec<String>,
    pub relevance_reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchitecturalDynamics {
    pub boundary_crossings: Vec<BoundaryCrossing>,
    pub subsystem_instabilities: Vec<SubsystemInstability>,
    pub historical_precedents: Vec<HistoricalPrecedent>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InvestigateFactBundle {
    pub metadata: BundleMetadata,
    pub entities: Vec<SemanticEntity>,
    pub relationships: Vec<Relationship>,
    pub impact: Option<StructuralImpact>,
    pub co_changes: Vec<CoChangeRelationship>,
    pub entity_histories: Vec<EntityHistory>,
    pub invariants: Vec<InvariantCheck>,
    pub forge_artifact: Option<ForgeArtifact>,
    pub traceability_links: Vec<TraceabilityLink>,
    #[serde(default)]
    pub dynamics: Option<ArchitecturalDynamics>,
}
