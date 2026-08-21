mod apps;
mod config;
mod ipc;
mod launch;

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
    let launch_paths = apps::launch_paths(&desktop_files, &applications);
    let launcher = std::sync::Arc::new(launch::LaunchService::new(&applications, launch_paths));

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
    ipc::serve(config, applications.into(), launcher).await
}
