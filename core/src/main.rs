mod apps;
mod config;
mod ipc;

use anyhow::Result;
use tracing::{debug, info};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .init();

    let config = config::CoreConfig::from_environment()?;
    let application_directories = apps::application_directories()?;
    let desktop_files = apps::discover_desktop_files(&application_directories)?;

    info!(?application_directories, "application search path resolved");
    info!(
        applications = desktop_files.len(),
        "desktop application files discovered"
    );
    for desktop_file in desktop_files.iter().take(5) {
        debug!(
            desktop_id = %desktop_file.id,
            path = %desktop_file.path.display(),
            "desktop file discovered"
        );
    }
    info!(socket = %config.socket_path.display(), "Velora Core starting");
    ipc::serve(config).await
}
