use anyhow::Result;
use std::path::PathBuf;
use velora_protocol::default_socket_path;

#[derive(Debug, Clone)]
pub struct CoreConfig {
    pub socket_path: PathBuf,
}

impl CoreConfig {
    pub fn from_environment() -> Result<Self> {
        Ok(Self {
            socket_path: default_socket_path()?,
        })
    }
}
