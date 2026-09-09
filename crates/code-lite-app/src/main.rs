mod frontend;
mod server;
mod state;

use state::AppState;
use std::sync::Arc;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let current_dir = std::env::current_dir()?;
    println!("Initializing CodeLiteX workspace: {}", current_dir.display());

    let state = Arc::new(AppState::new(&current_dir)?);
    println!("SQLite database ready at .codelite/workspace.db");

    let port = 4096;
    server::run_server(state, port)?;
    Ok(())
}
