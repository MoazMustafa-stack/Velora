use anyhow::{Context, Result, bail};
use tokio::process::Command;
use tracing::info;

/// A deliberately narrow v0.1 launcher. Desktop-file discovery arrives in a
/// later milestone; requests can never be interpreted as shell commands.
pub async fn launch(desktop_id: &str) -> Result<()> {
    let executable = match desktop_id {
        "code.desktop" => "code",
        "codium.desktop" => "codium",
        _ => bail!("application is not available in the v0.1 demo catalog: {desktop_id}"),
    };

    Command::new(executable)
        .spawn()
        .with_context(|| format!("failed to launch {executable}"))?;
    info!(desktop_id, "launched application");
    Ok(())
    
}
