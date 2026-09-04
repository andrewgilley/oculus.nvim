use std::collections::HashMap;
use crate::models::{CoChangeRelationship, GitCommitRecord};

pub struct ChangeCouplingMiner;

impl ChangeCouplingMiner {
    pub fn mine_co_changes(
        commits: &[GitCommitRecord],
        min_co_changes: usize,
        min_confidence: f64,
    ) -> Vec<CoChangeRelationship> {
        let mut file_commit_counts: HashMap<String, usize> = HashMap::new();
        let mut pair_counts: HashMap<(String, String), (usize, Vec<String>)> = HashMap::new();

        for commit in commits {
            // Filter out massive merge commits or repo-wide bulk operations that skew coupling
            if commit.changed_files.len() > 35 || commit.changed_files.len() < 2 {
                continue;
            }

            for file in &commit.changed_files {
                *file_commit_counts.entry(file.clone()).or_insert(0) += 1;
            }

            let mut sorted_files = commit.changed_files.clone();
            sorted_files.sort();
            sorted_files.dedup();

            for i in 0..sorted_files.len() {
                for j in (i + 1)..sorted_files.len() {
                    let pair = (sorted_files[i].clone(), sorted_files[j].clone());
                    let entry = pair_counts.entry(pair).or_insert((0, Vec::new()));
                    entry.0 += 1;
                    if entry.1.len() < 5 {
                        entry.1.push(commit.oid.clone());
                    }
                }
            }
        }

        let mut results = Vec::new();

        for ((a, b), (co_count, samples)) in pair_counts {
            if co_count < min_co_changes {
                continue;
            }

            let count_a = *file_commit_counts.get(&a).unwrap_or(&1);
            let count_b = *file_commit_counts.get(&b).unwrap_or(&1);

            // Jaccard similarity: intersection / union
            let union = count_a + count_b - co_count;
            let jaccard = if union > 0 {
                co_count as f64 / union as f64
            } else {
                0.0
            };

            if jaccard >= min_confidence {
                results.push(CoChangeRelationship {
                    entity_a: a,
                    entity_b: b,
                    co_change_count: co_count,
                    confidence: (jaccard * 100.0).round() / 100.0,
                    sample_commits: samples,
                });
            }
        }

        results.sort_by(|x, y| {
            y.co_change_count
                .cmp(&x.co_change_count)
                .then(y.confidence.partial_cmp(&x.confidence).unwrap_or(std::cmp::Ordering::Equal))
        });

        results
    }
}
