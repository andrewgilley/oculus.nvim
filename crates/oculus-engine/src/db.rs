use std::path::Path;
use rusqlite::{params, Connection, Result};

use crate::models::{
    CoChangeRelationship, EntityChangeRecord, EntityHistory, EntityKind, GitCommitRecord,
    Relationship, SemanticEntity,
};

pub struct Database {
    conn: Connection,
}

impl Database {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = Connection::open(path)?;
        let db = Database { conn };
        db.init_schema()?;
        Ok(db)
    }

    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        let db = Database { conn };
        db.init_schema()?;
        Ok(db)
    }

    fn init_schema(&self) -> Result<()> {
        self.conn.execute_batch(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;

            CREATE TABLE IF NOT EXISTS entities (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                qualified_name TEXT NOT NULL,
                file_path TEXT NOT NULL,
                start_line INTEGER NOT NULL,
                end_line INTEGER NOT NULL,
                start_col INTEGER NOT NULL,
                end_col INTEGER NOT NULL,
                git_oid TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_entities_file_path ON entities(file_path);
            CREATE INDEX IF NOT EXISTS idx_entities_qualified_name ON entities(qualified_name);
            CREATE INDEX IF NOT EXISTS idx_entities_lines ON entities(file_path, start_line, end_line);

            CREATE TABLE IF NOT EXISTS relationships (
                source_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                confidence REAL NOT NULL,
                provenance TEXT NOT NULL,
                PRIMARY KEY (source_id, target_id, kind)
            );

            CREATE INDEX IF NOT EXISTS idx_rel_source ON relationships(source_id);
            CREATE INDEX IF NOT EXISTS idx_rel_target ON relationships(target_id);

            CREATE TABLE IF NOT EXISTS git_commits (
                oid TEXT PRIMARY KEY,
                parent_oids TEXT NOT NULL,
                author TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                message TEXT NOT NULL,
                changed_files TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS entity_changes (
                commit_oid TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                change_kind TEXT NOT NULL,
                old_start INTEGER,
                old_end INTEGER,
                new_start INTEGER,
                new_end INTEGER,
                PRIMARY KEY (commit_oid, entity_id)
            );

            CREATE INDEX IF NOT EXISTS idx_change_entity ON entity_changes(entity_id);
            CREATE INDEX IF NOT EXISTS idx_change_commit ON entity_changes(commit_oid);

            CREATE TABLE IF NOT EXISTS co_changes (
                entity_a TEXT NOT NULL,
                entity_b TEXT NOT NULL,
                co_change_count INTEGER NOT NULL,
                confidence REAL NOT NULL,
                sample_commits TEXT NOT NULL,
                PRIMARY KEY (entity_a, entity_b)
            );
            ",
        )?;
        Ok(())
    }

    pub fn insert_entities(&mut self, entities: &[SemanticEntity]) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT OR REPLACE INTO entities 
                 (id, kind, name, qualified_name, file_path, start_line, end_line, start_col, end_col, git_oid)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )?;
            for e in entities {
                let kind_str = serde_json::to_string(&e.kind).unwrap_or_default();
                let clean_kind = kind_str.trim_matches('"');
                stmt.execute(params![
                    e.id,
                    clean_kind,
                    e.name,
                    e.qualified_name,
                    e.file_path,
                    e.start_line as i64,
                    e.end_line as i64,
                    e.start_col as i64,
                    e.end_col as i64,
                    e.git_oid,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn insert_relationships(&mut self, rels: &[Relationship]) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT OR REPLACE INTO relationships
                 (source_id, target_id, kind, confidence, provenance)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;
            for r in rels {
                let kind_str = serde_json::to_string(&r.kind).unwrap_or_default();
                let clean_kind = kind_str.trim_matches('"');
                let prov_str = serde_json::to_string(&r.provenance).unwrap_or_default();
                stmt.execute(params![
                    r.source_id,
                    r.target_id,
                    clean_kind,
                    r.confidence,
                    prov_str,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn insert_commit(&mut self, c: &GitCommitRecord) -> Result<()> {
        let parents = serde_json::to_string(&c.parent_oids).unwrap_or_default();
        let files = serde_json::to_string(&c.changed_files).unwrap_or_default();
        self.conn.execute(
            "INSERT OR REPLACE INTO git_commits
             (oid, parent_oids, author, timestamp, message, changed_files)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![c.oid, parents, c.author, c.timestamp, c.message, files],
        )?;
        Ok(())
    }

    pub fn insert_entity_changes(&mut self, changes: &[EntityChangeRecord]) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT OR REPLACE INTO entity_changes
                 (commit_oid, entity_id, file_path, change_kind, old_start, old_end, new_start, new_end)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            )?;
            for ch in changes {
                let (old_s, old_e) = ch.old_line_range.map(|(s, e)| (Some(s as i64), Some(e as i64))).unwrap_or((None, None));
                let (new_s, new_e) = ch.new_line_range.map(|(s, e)| (Some(s as i64), Some(e as i64))).unwrap_or((None, None));
                stmt.execute(params![
                    ch.commit_oid,
                    ch.entity_id,
                    ch.file_path,
                    ch.change_kind,
                    old_s,
                    old_e,
                    new_s,
                    new_e,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_entities_in_file(&self, path: &str) -> Result<Vec<SemanticEntity>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, kind, name, qualified_name, file_path, start_line, end_line, start_col, end_col, git_oid
             FROM entities WHERE file_path = ?1 ORDER BY start_line ASC",
        )?;
        let rows = stmt.query_map(params![path], |row| {
            let kind_str: String = row.get(1)?;
            let kind: EntityKind = serde_json::from_str(&format!("\"{}\"", kind_str))
                .unwrap_or(EntityKind::Function);
            Ok(SemanticEntity {
                id: row.get(0)?,
                kind,
                name: row.get(2)?,
                qualified_name: row.get(3)?,
                file_path: row.get(4)?,
                start_line: row.get::<_, i64>(5)? as usize,
                end_line: row.get::<_, i64>(6)? as usize,
                start_col: row.get::<_, i64>(7)? as usize,
                end_col: row.get::<_, i64>(8)? as usize,
                git_oid: row.get(9)?,
            })
        })?;

        let mut result = Vec::new();
        for r in rows {
            result.push(r?);
        }
        Ok(result)
    }

    pub fn get_entity_at_line(&self, file_path: &str, line: usize) -> Result<Option<SemanticEntity>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, kind, name, qualified_name, file_path, start_line, end_line, start_col, end_col, git_oid
             FROM entities
             WHERE file_path = ?1 AND start_line <= ?2 AND end_line >= ?2
             ORDER BY (end_line - start_line) ASC LIMIT 1",
        )?;
        let mut rows = stmt.query(params![file_path, line as i64])?;
        if let Some(row) = rows.next()? {
            let kind_str: String = row.get(1)?;
            let kind: EntityKind = serde_json::from_str(&format!("\"{}\"", kind_str))
                .unwrap_or(EntityKind::Function);
            Ok(Some(SemanticEntity {
                id: row.get(0)?,
                kind,
                name: row.get(2)?,
                qualified_name: row.get(3)?,
                file_path: row.get(4)?,
                start_line: row.get::<_, i64>(5)? as usize,
                end_line: row.get::<_, i64>(6)? as usize,
                start_col: row.get::<_, i64>(7)? as usize,
                end_col: row.get::<_, i64>(8)? as usize,
                git_oid: row.get(9)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn get_callers(&self, entity_id: &str) -> Result<Vec<SemanticEntity>> {
        let mut stmt = self.conn.prepare(
            "SELECT e.id, e.kind, e.name, e.qualified_name, e.file_path, e.start_line, e.end_line, e.start_col, e.end_col, e.git_oid
             FROM relationships r
             JOIN entities e ON r.source_id = e.id
             WHERE r.target_id = ?1 AND r.kind = 'calls'",
        )?;
        let rows = stmt.query_map(params![entity_id], |row| {
            let kind_str: String = row.get(1)?;
            let kind: EntityKind = serde_json::from_str(&format!("\"{}\"", kind_str))
                .unwrap_or(EntityKind::Function);
            Ok(SemanticEntity {
                id: row.get(0)?,
                kind,
                name: row.get(2)?,
                qualified_name: row.get(3)?,
                file_path: row.get(4)?,
                start_line: row.get::<_, i64>(5)? as usize,
                end_line: row.get::<_, i64>(6)? as usize,
                start_col: row.get::<_, i64>(7)? as usize,
                end_col: row.get::<_, i64>(8)? as usize,
                git_oid: row.get(9)?,
            })
        })?;

        let mut callers = Vec::new();
        for c in rows {
            callers.push(c?);
        }
        Ok(callers)
    }

    pub fn get_entity_history(&self, entity_id: &str) -> Result<EntityHistory> {
        let mut stmt = self.conn.prepare(
            "SELECT qualified_name FROM entities WHERE id = ?1",
        )?;
        let qualified_name: String = stmt.query_row(params![entity_id], |row| row.get(0))
            .unwrap_or_else(|_| entity_id.to_string());

        let mut commit_stmt = self.conn.prepare(
            "SELECT ec.commit_oid, c.author, c.timestamp
             FROM entity_changes ec
             JOIN git_commits c ON ec.commit_oid = c.oid
             WHERE ec.entity_id = ?1
             ORDER BY c.timestamp ASC",
        )?;
        let rows = commit_stmt.query_map(params![entity_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
        })?;

        let mut total_commits = 0;
        let mut authors = std::collections::HashSet::new();
        let mut first_commit = None;
        let mut last_timestamp = None;

        for r in rows {
            let (oid, author, ts) = r?;
            if first_commit.is_none() {
                first_commit = Some(oid);
            }
            authors.insert(author);
            last_timestamp = Some(ts);
            total_commits += 1;
        }

        Ok(EntityHistory {
            entity_id: entity_id.to_string(),
            qualified_name,
            introduction_commit: first_commit,
            total_commits,
            authors: authors.into_iter().collect(),
            last_modified: last_timestamp.map(|t| t.to_string()),
        })
    }

    pub fn insert_co_changes(&mut self, co_changes: &[CoChangeRelationship]) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT OR REPLACE INTO co_changes
                 (entity_a, entity_b, co_change_count, confidence, sample_commits)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;
            for cc in co_changes {
                let samples = serde_json::to_string(&cc.sample_commits).unwrap_or_default();
                stmt.execute(params![
                    cc.entity_a,
                    cc.entity_b,
                    cc.co_change_count as i64,
                    cc.confidence,
                    samples,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_co_changes_for(&self, entity_or_file: &str) -> Result<Vec<CoChangeRelationship>> {
        let mut stmt = self.conn.prepare(
            "SELECT entity_a, entity_b, co_change_count, confidence, sample_commits
             FROM co_changes
             WHERE entity_a = ?1 OR entity_b = ?1
             ORDER BY co_change_count DESC LIMIT 20",
        )?;
        let rows = stmt.query_map(params![entity_or_file], |row| {
            let samples_str: String = row.get(4)?;
            let sample_commits = serde_json::from_str(&samples_str).unwrap_or_default();
            Ok(CoChangeRelationship {
                entity_a: row.get(0)?,
                entity_b: row.get(1)?,
                co_change_count: row.get::<_, i64>(2)? as usize,
                confidence: row.get(3)?,
                sample_commits,
            })
        })?;

        let mut results = Vec::new();
        for r in rows {
            results.push(r?);
        }
        Ok(results)
    }
}
