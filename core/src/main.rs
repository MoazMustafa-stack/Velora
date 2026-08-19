mod config;
mod ipc;

use anyhow::Result;
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .init();

    let config = config::CoreConfig::from_environment()?;
    info!(socket = %config.socket_path.display(), "Velora Core starting");
    ipc::serve(config).await
}
