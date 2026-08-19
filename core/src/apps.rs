use anyhow::{Context, Result};
use std::{
    collections::HashSet,
    env,
    ffi::{OsStr, OsString},
    path::{Path, PathBuf},
};

const DEFAULT_XDG_DATA_DIRS: &str = "/usr/local/share:/usr/share";

pub fn application_directories() -> Result<Vec<PathBuf>> {
    resolve_application_directories(
        env::var_os("HOME").as_deref().map(Path::new),
        env::var_os("XDG_DATA_HOME").as_deref(),
        env::var_os("XDG_DATA_DIRS").as_deref(),
    )
}

fn resolve_application_directories(
    home: Option<&Path>,
    data_home: Option<&OsStr>,
    data_dirs: Option<&OsStr>,
) -> Result<Vec<PathBuf>> {
    let user_data_directory = data_home
        .and_then(absolute_path)
        .or_else(|| home.map(|path| path.join(".local/share")))
        .context("HOME or an absolute XDG_DATA_HOME is required")?;

    let system_data_value = data_dirs
        .filter(|value| !value.is_empty())
        .map(OsString::from)
        .unwrap_or_else(|| OsString::from(DEFAULT_XDG_DATA_DIRS));

    let mut directories = vec![user_data_directory.join("applications")];

    directories.extend(
        env::split_paths(&system_data_value)
            .filter(|path| path.is_absolute())
            .map(|path| path.join("applications")),
    );

    let mut seen = HashSet::new();
    directories.retain(|path| seen.insert(path.clone()));

    Ok(directories)
}

fn absolute_path(value: &OsStr) -> Option<PathBuf> {
    let path = PathBuf::from(value);
    path.is_absolute().then_some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_freedesktop_defaults() {
        let directories =
            resolve_application_directories(Some(Path::new("/home/tester")), None, None).unwrap();

        assert_eq!(
            directories,
            vec![
                PathBuf::from("/home/tester/.local/share/applications"),
                PathBuf::from("/usr/local/share/applications"),
                PathBuf::from("/usr/share/applications"),
            ]
        );
    }

    #[test]
    fn respects_xdg_precedence_and_removes_duplicates() {
        let directories = resolve_application_directories(
            Some(Path::new("/home/tester")),
            Some(OsStr::new("/custom/user-data")),
            Some(OsStr::new("/opt/share:/usr/share:/opt/share:relative-path")),
        )
        .unwrap();

        assert_eq!(
            directories,
            vec![
                PathBuf::from("/custom/user-data/applications"),
                PathBuf::from("/opt/share/applications"),
                PathBuf::from("/usr/share/applications"),
            ]
        );
    }

    #[test]
    fn rejects_missing_user_data_location() {
        let result = resolve_application_directories(None, None, None);
        assert!(result.is_err());
    }

    #[test]
    fn accepts_absolute_data_home_without_home() {
        let directories =
            resolve_application_directories(None, Some(OsStr::new("/custom/user-data")), None)
                .unwrap();

        assert_eq!(
            directories,
            vec![
                PathBuf::from("/custom/user-data/applications"),
                PathBuf::from("/usr/local/share/applications"),
                PathBuf::from("/usr/share/applications"),
            ]
        );
    }
}
