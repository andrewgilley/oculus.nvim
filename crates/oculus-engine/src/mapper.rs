use crate::db::Database;
use crate::git::GitDiffHunk;
use crate::models::{EntityChangeRecord, SemanticEntity};

pub struct GitSemanticMapper;

impl GitSemanticMapper {
    pub fn map_diff_to_entities(
        db: &Database,
        commit_oid: &str,
        hunks: &[GitDiffHunk],
    ) -> Vec<(EntityChangeRecord, SemanticEntity)> {
        let mut results = Vec::new();

        for hunk in hunks {
            let entities = match db.get_entities_in_file(&hunk.file_path) {
                Ok(e) => e,
                Err(_) => continue,
            };

            let (range_start, range_end) = if hunk.new_lines > 0 {
                (hunk.new_start, hunk.new_start + hunk.new_lines.saturating_sub(1))
            } else {
                (hunk.old_start, hunk.old_start + hunk.old_lines.saturating_sub(1))
            };

            for entity in entities {
                // Check interval overlap: max(start1, start2) <= min(end1, end2)
                let overlap_start = range_start.max(entity.start_line);
                let overlap_end = range_end.min(entity.end_line);

                if overlap_start <= overlap_end {
                    let change_record = EntityChangeRecord {
                        commit_oid: commit_oid.to_string(),
                        entity_id: entity.id.clone(),
                        file_path: hunk.file_path.clone(),
                        change_kind: hunk.change_type.clone(),
                        old_line_range: if hunk.old_lines > 0 {
                            Some((hunk.old_start, hunk.old_start + hunk.old_lines))
                        } else {
                            None
                        },
                        new_line_range: if hunk.new_lines > 0 {
                            Some((hunk.new_start, hunk.new_start + hunk.new_lines))
                        } else {
                            None
                        },
                    };

                    results.push((change_record, entity));
                }
            }
        }

        results
    }
}
