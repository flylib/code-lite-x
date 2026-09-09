use crate::error::StorageError;
use crate::schema::initialize_schema;
use parking_lot::Mutex;
use rusqlite::Connection;
use std::path::Path;
use std::sync::Arc;

/// Thread-safe SQLite Database manager for CodeLiteX.
#[derive(Clone)]
pub struct Database {
    conn: Arc<Mutex<Connection>>,
}

impl Database {
    /// Opens an in-memory database (useful for unit tests and temporary workspaces).
    pub fn open_in_memory() -> Result<Self, StorageError> {
        let conn = Connection::open_in_memory()?;
        Self::configure_and_init(conn)
    }

    /// Opens or creates a file-backed SQLite database at the specified path.
    /// Automatically creates parent directories if needed.
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self, StorageError> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let conn = Connection::open(path)?;
        Self::configure_and_init(conn)
    }

    fn configure_and_init(conn: Connection) -> Result<Self, StorageError> {
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA busy_timeout = 5000;
            "#,
        )?;

        initialize_schema(&conn)?;

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Executes a closure with a reference to the SQLite connection.
    pub fn with_conn<F, R>(&self, f: F) -> Result<R, StorageError>
    where
        F: FnOnce(&Connection) -> Result<R, StorageError>,
    {
        let guard = self.conn.lock();
        f(&guard)
    }

    /// Executes a closure with a mutable reference to the SQLite connection (e.g. for transactions).
    pub fn with_conn_mut<F, R>(&self, f: F) -> Result<R, StorageError>
    where
        F: FnOnce(&mut Connection) -> Result<R, StorageError>,
    {
        let mut guard = self.conn.lock();
        f(&mut guard)
    }
}
