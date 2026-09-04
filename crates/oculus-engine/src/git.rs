use std::path::Path;
use std::process::Command;
use crate::models::GitCommitRecord;

#[derive(Debug, Clone)]
pub struct GitDiffHunk {
    pub file_path: String,
    pub old_start: usize,
    pub old_lines: usize,
    pub new_start: usize,
    pub new_lines: usize,
    pub change_type: String,
}

pub struct GitReader;

impl GitReader {
    pub fn find_repo_root<P: AsRef<Path>>(path: P) -> Option<std::path::PathBuf> {
        let output = Command::new("git")
            .arg("-C")
            .arg(path.as_ref())
            .args(["rev-parse", "--show-toplevel"])
            .output()
            .ok()?;

        if output.status.success() {
            let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !s.is_empty() {
                return Some(std::path::PathBuf::from(s));
            }
        }
        None
    }

    pub fn current_head<P: AsRef<Path>>(repo_root: P) -> Option<String> {
        let output = Command::new("git")
            .arg("-C")
            .arg(repo_root.as_ref())
            .args(["rev-parse", "HEAD"])
            .output()
            .ok()?;

        if output.status.success() {
            let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
        None
    }

    pub fn commit_history<P: AsRef<Path>>(repo_root: P, limit: usize) -> Vec<GitCommitRecord> {
        let output = match Command::new("git")
            .arg("-C")
            .arg(repo_root.as_ref())
            .args([
                "log",
                "--pretty=format:COMMIT:%H%x1f%P%x1f%an%x1f%at%x1f%s",
                "--name-only",
                "-n",
                &limit.to_string(),
            ])
            .output()
        {
            Ok(out) if out.status.success() => out,
            _ => return Vec::new(),
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut records = Vec::new();
        let mut current_record: Option<GitCommitRecord> = None;

        for line in stdout.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }

            if line.starts_with("COMMIT:") {
                if let Some(r) = current_record.take() {
                    records.push(r);
                }

                let parts: Vec<&str> = line[7..].split('\x1f').collect();
                if parts.len() >= 5 {
                    let oid = parts[0].to_string();
                    let parents = parts[1]
                        .split_whitespace()
                        .map(|s| s.to_string())
                        .collect();
                    let author = parts[2].to_string();
                    let timestamp = parts[3].parse::<i64>().unwrap_or(0);
                    let message = parts[4].to_string();

                    current_record = Some(GitCommitRecord {
                        oid,
                        parent_oids: parents,
                        author,
                        timestamp,
                        message,
                        changed_files: Vec::new(),
                    });
                }
            } else if let Some(ref mut record) = current_record {
                record.changed_files.push(line.replace('\\', "/"));
            }
        }

        if let Some(r) = current_record {
            records.push(r);
        }

        records
    }

    pub fn commit_diff_hunks<P: AsRef<Path>>(repo_root: P, commit: &str) -> Vec<GitDiffHunk> {
        let output = match Command::new("git")
            .arg("-C")
            .arg(repo_root.as_ref())
            .args(["show", "--unified=0", "--format=", commit])
            .output()
        {
            Ok(out) if out.status.success() => out,
            _ => return Vec::new(),
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        Self::parse_diff_hunks(&stdout)
    }

    pub fn uncommitted_diff_hunks<P: AsRef<Path>>(repo_root: P) -> Vec<GitDiffHunk> {
        let output = match Command::new("git")
            .arg("-C")
            .arg(repo_root.as_ref())
            .args(["diff", "--unified=0"])
            .output()
        {
            Ok(out) if out.status.success() => out,
            _ => return Vec::new(),
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        Self::parse_diff_hunks(&stdout)
    }

    fn parse_diff_hunks(diff_text: &str) -> Vec<GitDiffHunk> {
        let mut hunks = Vec::new();
        let mut current_file = String::new();

        for line in diff_text.lines() {
            if line.starts_with("diff --git ") {
                if let Some(b_idx) = line.find(" b/") {
                    current_file = line[b_idx + 3..].replace('\\', "/");
                }
            } else if line.starts_with("@@ ") && !current_file.is_empty() {
                if let Some((old_range, new_range)) = Self::parse_hunk_header(line) {
                    let change_type = if old_range.1 == 0 && new_range.1 > 0 {
                        "added".to_string()
                    } else if old_range.1 > 0 && new_range.1 == 0 {
                        "deleted".to_string()
                    } else {
                        "modified".to_string()
                    };

                    hunks.push(GitDiffHunk {
                        file_path: current_file.clone(),
                        old_start: old_range.0,
                        old_lines: old_range.1,
                        new_start: new_range.0,
                        new_lines: new_range.1,
                        change_type,
                    });
                }
            }
        }

        hunks
    }

    fn parse_hunk_header(line: &str) -> Option<((usize, usize), (usize, usize))> {
        let trimmed = line.trim_start_matches('@').trim();
        let end_idx = trimmed.find("@@")?;
        let header = &trimmed[..end_idx].trim();
        let parts: Vec<&str> = header.split_whitespace().collect();
        if parts.len() < 2 {
            return None;
        }

        let parse_side = |s: &str| -> Option<(usize, usize)> {
            let s = s.trim_start_matches('-').trim_start_matches('+');
            if let Some(comma_pos) = s.find(',') {
                let start = s[..comma_pos].parse::<usize>().ok()?;
                let lines = s[comma_pos + 1..].parse::<usize>().ok()?;
                Some((start, lines))
            } else {
                let start = s.parse::<usize>().ok()?;
                Some((start, 1))
            }
        };

        let old = parse_side(parts[0])?;
        let new = parse_side(parts[1])?;
        Some((old, new))
    }
}
