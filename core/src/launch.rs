use freedesktop_desktop_entry::DesktopEntry;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use thiserror::Error;
use tokio::process::Command;
use velora_protocol::Application;

const MAX_ACTIVE_PROCESSES: usize = 8;
const LAUNCH_COOLDOWN: Duration = Duration::from_millis(500);

#[derive(Debug, Clone)]
struct LaunchTarget {
    application: Application,
    desktop_file: PathBuf,
}

#[derive(Debug, Default)]
struct LaunchState {
    active_processes: usize,
    last_launch: HashMap<String, Instant>,
}

#[derive(Debug, Error)]
pub enum LaunchError {
    #[error("application is not present in the registry")]
    UnknownApplication,

    #[error("terminal applications require an explicit terminal policy")]
    TerminalRequired,

    #[error("desktop entry is malformed: {0}")]
    MalformedEntry(String),

    #[error("desktop entry uses unsupported Exec field codes")]
    UnsupportedFieldCode,

    #[error("shell wrappers are not allowed")]
    ShellWrapperRejected,

    #[error("executable is not available: {0}")]
    ExecutableUnavailable(String),

    #[error("launch rate limit exceeded")]
    RateLimited,

    #[error("maximum active process limit reached")]
    ProcessLimitReached,

    #[error("failed to launch application: {0}")]
    Spawn(#[source] std::io::Error),
}

impl LaunchError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownApplication => "unknown_application",
            Self::TerminalRequired => "terminal_required",
            Self::MalformedEntry(_) => "malformed_desktop_entry",
            Self::UnsupportedFieldCode => "unsupported_exec_field",
            Self::ShellWrapperRejected => "shell_wrapper_rejected",
            Self::ExecutableUnavailable(_) => "executable_unavailable",
            Self::RateLimited => "launch_rate_limited",
            Self::ProcessLimitReached => "launch_process_limit",
            Self::Spawn(_) => "launch_failed",
        }
    }
}

#[derive(Clone)]
pub struct LaunchService {
    targets: Arc<HashMap<String, LaunchTarget>>,
    state: Arc<Mutex<LaunchState>>,
}

impl LaunchService {
    pub fn new(applications: &[Application], launch_paths: HashMap<String, PathBuf>) -> Self {
        let targets = applications
            .iter()
            .filter_map(|application| {
                launch_paths
                    .get(&application.id)
                    .cloned()
                    .map(|desktop_file| {
                        (
                            application.id.clone(),
                            LaunchTarget {
                                application: application.clone(),
                                desktop_file,
                            },
                        )
                    })
            })
            .collect();

        Self {
            targets: Arc::new(targets),
            state: Arc::new(Mutex::new(LaunchState::default())),
        }
    }

    #[cfg(test)]
    pub fn empty() -> Self {
        Self {
            targets: Arc::new(HashMap::new()),
            state: Arc::new(Mutex::new(LaunchState::default())),
        }
    }

    pub async fn launch(&self, desktop_id: &str) -> Result<u32, LaunchError> {
        let target = self
            .targets
            .get(desktop_id)
            .cloned()
            .ok_or(LaunchError::UnknownApplication)?;

        if target.application.terminal {
            return Err(LaunchError::TerminalRequired);
        }

        let locales = freedesktop_desktop_entry::get_languages_from_env();
        let entry = DesktopEntry::from_path(&target.desktop_file, Some(&locales))
            .map_err(|error| LaunchError::MalformedEntry(error.to_string()))?;

        if entry.type_() != Some("Application") || entry.hidden() || entry.no_display() {
            return Err(LaunchError::UnknownApplication);
        }

        let raw_exec = entry
            .exec()
            .ok_or_else(|| LaunchError::MalformedEntry("missing Exec".to_owned()))?;

        // P2.06 intentionally has no file/URI payload support.
        if raw_exec.contains('%') {
            return Err(LaunchError::UnsupportedFieldCode);
        }

        let args = entry
            .parse_exec()
            .map_err(|error| LaunchError::MalformedEntry(error.to_string()))?;

        let program = args
            .first()
            .ok_or_else(|| LaunchError::MalformedEntry("empty Exec".to_owned()))?;

        if is_shell_wrapper(&args) {
            return Err(LaunchError::ShellWrapperRejected);
        }

        if !executable_available(program) {
            return Err(LaunchError::ExecutableUnavailable(program.clone()));
        }

        if let Some(try_exec) = entry.try_exec()
            && !executable_available(try_exec)
        {
            return Err(LaunchError::ExecutableUnavailable(try_exec.to_owned()));
        }

        {
            let mut state = self.state.lock().expect("launch state poisoned");

            if state.active_processes >= MAX_ACTIVE_PROCESSES {
                return Err(LaunchError::ProcessLimitReached);
            }

            if let Some(last_launch) = state.last_launch.get(desktop_id)
                && last_launch.elapsed() < LAUNCH_COOLDOWN
            {
                return Err(LaunchError::RateLimited);
            }

            state.active_processes += 1;
            state
                .last_launch
                .insert(desktop_id.to_owned(), Instant::now());
        }

        let spawn_result = Command::new(program).args(&args[1..]).spawn();

        let mut child = match spawn_result {
            Ok(child) => child,
            Err(error) => {
                self.state
                    .lock()
                    .expect("launch state poisoned")
                    .active_processes -= 1;
                return Err(LaunchError::Spawn(error));
            }
        };

        let process_id = child
            .id()
            .ok_or_else(|| LaunchError::MalformedEntry("missing process ID".to_owned()))?;

        let state = Arc::clone(&self.state);
        tokio::spawn(async move {
            let _ = child.wait().await;
            state
                .lock()
                .expect("launch state poisoned")
                .active_processes -= 1;
        });

        Ok(process_id)
    }
}

fn is_shell_wrapper(args: &[String]) -> bool {
    let Some(program) = args.first() else {
        return false;
    };

    let executable = Path::new(program)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default();

    matches!(executable, "sh" | "bash" | "zsh" | "fish")
        && args.iter().skip(1).any(|arg| arg == "-c" || arg == "-lc")
}

fn executable_available(program: &str) -> bool {
    let path = Path::new(program);

    if path.is_absolute() {
        return is_executable_file(path);
    }

    let Some(path_value) = std::env::var_os("PATH") else {
        return false;
    };

    std::env::split_paths(&path_value)
        .map(|directory| directory.join(program))
        .any(|candidate| is_executable_file(&candidate))
}

fn is_executable_file(path: &Path) -> bool {
    use std::{fs, os::unix::fs::PermissionsExt};

    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
