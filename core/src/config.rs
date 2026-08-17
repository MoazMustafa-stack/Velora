use anyhow::{Context, Result};
use std::{env, path::PathBuf};

#[derive(Debug, Clone)]
pub struct CoreConfig {
    pub socket_path: PathBuf,
}

impl CoreConfig {
    pub fn from_environment() -> Result<Self> {
        let socket_path = env::var_os("VELORA_SOCKET").map(PathBuf::from).unwrap_or(
            match env::var_os("XDG_RUNTIME_DIR") {
                Some(runtime_dir) => PathBuf::from(runtime_dir).join("velora.sock"),
                None => PathBuf::from(format!("/tmp/velora-{}.sock", users_uid()?)),
            },
        );
        Ok(Self { socket_path })
    }
}

fn users_uid() -> Result<u32> {
    let uid = env::var("UID").context("XDG_RUNTIME_DIR and UID are unavailable")?;
    uid.parse().context("UID is not numeric")
}
