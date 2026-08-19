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
    let applications = apps::load_applications(&desktop_files);

    info!(?application_directories, "application search path resolved");
    info!(
        desktop_files = desktop_files.len(),
        applications = applications.len(),
        "desktop applications loaded"
    );
    for application in applications.iter().take(5) {
        debug!(
            desktop_id = %application.id,
            name = %application.name,
            terminal = application.terminal,
            "application registered"
        );
    }
    info!(socket = %config.socket_path.display(), "Velora Core starting");
    ipc::serve(config).await
}
