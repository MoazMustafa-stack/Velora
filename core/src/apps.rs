use anyhow::{Context, Result};
use freedesktop_desktop_entry::{DesktopEntry, get_languages_from_env};
use std::collections::{HashMap, HashSet};
use std::{
    env,
    ffi::{OsStr, OsString},
    fs, io,
    path::{Path, PathBuf},
};
use tracing::{debug, warn};
use velora_protocol::Application;

const DEFAULT_XDG_DATA_DIRS: &str = "/usr/local/share:/usr/share";

pub fn application_directories() -> Result<Vec<PathBuf>> {
    resolve_application_directories(
        env::var_os("HOME").as_deref().map(Path::new),
        env::var_os("XDG_DATA_HOME").as_deref(),
        env::var_os("XDG_DATA_DIRS").as_deref(),
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopFile {
    pub id: String,
    pub path: PathBuf,
}

pub fn discover_desktop_files(directories: &[PathBuf]) -> Result<Vec<DesktopFile>> {
    let mut desktop_files = Vec::new();
    let mut seen_ids = HashSet::new();

    for directory in directories {
        collect_desktop_files(directory, directory, &mut seen_ids, &mut desktop_files)?;
    }

    Ok(desktop_files)
}

pub fn load_applications(desktop_files: &[DesktopFile]) -> Vec<Application> {
    let locales = get_languages_from_env();
    load_applications_with_locales(desktop_files, &locales)
}

fn load_applications_with_locales(
    desktop_files: &[DesktopFile],
    locales: &[String],
) -> Vec<Application> {
    let mut applications = desktop_files
        .iter()
        .filter_map(|desktop_file| parse_application(desktop_file, locales))
        .collect::<Vec<_>>();

    applications.sort_by(|left, right| {
        left.name
            .to_lowercase()
            .cmp(&right.name.to_lowercase())
            .then_with(|| left.id.cmp(&right.id))
    });
    applications
}

pub fn launch_paths(
    desktop_files: &[DesktopFile],
    applications: &[Application],
) -> HashMap<String, PathBuf> {
    let valid_ids: HashSet<&str> = applications
        .iter()
        .map(|application| application.id.as_str())
        .collect();

    desktop_files
        .iter()
        .filter(|desktop_file| valid_ids.contains(desktop_file.id.as_str()))
        .map(|desktop_file| (desktop_file.id.clone(), desktop_file.path.clone()))
        .collect()
}

fn parse_application(desktop_file: &DesktopFile, locales: &[String]) -> Option<Application> {
    let entry = match DesktopEntry::from_path(desktop_file.path.as_path(), Some(locales)) {
        Ok(entry) => entry,
        Err(error) => {
            warn!(
                path = %desktop_file.path.display(),
                %error,
                "skipping malformed desktop entry"
            );
            return None;
        }
    };

    if entry.type_() != Some("Application") || entry.hidden() || entry.no_display() {
        return None;
    }

    let name = entry.name(locales)?.trim().to_owned();
    let exec = entry.exec()?.trim().to_owned();
    if name.is_empty() || exec.is_empty() {
        debug!(
            desktop_id = %desktop_file.id,
            "skipping desktop entry without a usable Name or Exec"
        );
        return None;
    }

    let icon = entry
        .icon()
        .map(str::trim)
        .filter(|icon| !icon.is_empty())
        .map(str::to_owned);
    let categories = entry
        .categories()
        .unwrap_or_default()
        .into_iter()
        .map(str::trim)
        .filter(|category| !category.is_empty())
        .map(str::to_owned)
        .collect();

    Some(Application {
        id: desktop_file.id.clone(),
        name,
        exec,
        icon,
        categories,
        terminal: entry.terminal(),
    })
}

fn collect_desktop_files(
    root: &Path,
    current: &Path,
    seen_ids: &mut HashSet<String>,
    desktop_files: &mut Vec<DesktopFile>,
) -> Result<()> {
    let entries = match fs::read_dir(current) {
        Ok(entries) => entries,
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
            ) =>
        {
            return Ok(());
        }
        Err(error) => {
            return Err(error).with_context(|| {
                format!("cannot read application directory {}", current.display())
            });
        }
    };

    let mut entries = entries
        .collect::<io::Result<Vec<_>>>()
        .with_context(|| format!("cannot inspect application directory {}", current.display()))?;
    entries.sort_by_key(|entry| entry.file_name());

    for entry in entries {
        let path = entry.path();
        let file_type = entry
            .file_type()
            .with_context(|| format!("cannot inspect {}", path.display()))?;

        if file_type.is_dir() {
            collect_desktop_files(root, &path, seen_ids, desktop_files)?;
            continue;
        }

        if (!file_type.is_file() && !file_type.is_symlink())
            || path.extension() != Some(OsStr::new("desktop"))
        {
            continue;
        }

        let Some(id) = desktop_file_id(root, &path) else {
            continue;
        };

        if seen_ids.insert(id.clone()) {
            desktop_files.push(DesktopFile { id, path });
        }
    }

    Ok(())
}

fn desktop_file_id(root: &Path, path: &Path) -> Option<String> {
    path.strip_prefix(root)
        .ok()?
        .components()
        .map(|component| component.as_os_str().to_str())
        .collect::<Option<Vec<_>>>()
        .map(|components| components.join("-"))
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

    #[test]
    fn discovers_desktop_files_with_user_precedence() {
        let temporary_directory = tempfile::tempdir().unwrap();
        let user_directory = temporary_directory.path().join("user/applications");
        let system_directory = temporary_directory.path().join("system/applications");
        let nested_directory = system_directory.join("tools");

        fs::create_dir_all(&user_directory).unwrap();
        fs::create_dir_all(&nested_directory).unwrap();

        let user_firefox = user_directory.join("firefox.desktop");
        let system_firefox = system_directory.join("firefox.desktop");
        let nested_editor = nested_directory.join("editor.desktop");

        fs::write(&user_firefox, "[Desktop Entry]\nName=User Firefox\n").unwrap();
        fs::write(&system_firefox, "[Desktop Entry]\nName=System Firefox\n").unwrap();
        fs::write(&nested_editor, "[Desktop Entry]\nName=Editor\n").unwrap();
        fs::write(system_directory.join("notes.txt"), "not an application").unwrap();

        let desktop_files = discover_desktop_files(&[user_directory, system_directory]).unwrap();

        assert_eq!(
            desktop_files,
            vec![
                DesktopFile {
                    id: "firefox.desktop".to_owned(),
                    path: user_firefox,
                },
                DesktopFile {
                    id: "tools-editor.desktop".to_owned(),
                    path: nested_editor,
                },
            ]
        );
    }

    #[test]
    fn ignores_missing_application_directories() {
        let temporary_directory = tempfile::tempdir().unwrap();
        let missing_directory = temporary_directory.path().join("missing");

        let desktop_files = discover_desktop_files(&[missing_directory]).unwrap();

        assert!(desktop_files.is_empty());
    }

    #[test]
    fn parses_a_localized_application_model() {
        let temporary_directory = tempfile::tempdir().unwrap();
        let path = temporary_directory.path().join("editor.desktop");
        fs::write(
            &path,
            concat!(
                "[Desktop Entry]\n",
                "Type=Application\n",
                "Name=Editor\n",
                "Name[fr]=Éditeur\n",
                "Exec=editor --new-window %F\n",
                "Icon=editor\n",
                "Categories=Development;IDE;\n",
                "Terminal=false\n",
            ),
        )
        .unwrap();
        let files = vec![DesktopFile {
            id: "editor.desktop".to_owned(),
            path,
        }];

        let applications = load_applications_with_locales(&files, &["fr".to_owned()]);

        assert_eq!(
            applications,
            vec![Application {
                id: "editor.desktop".to_owned(),
                name: "Éditeur".to_owned(),
                exec: "editor --new-window %F".to_owned(),
                icon: Some("editor".to_owned()),
                categories: vec!["Development".to_owned(), "IDE".to_owned()],
                terminal: false,
            }]
        );
    }

    #[test]
    fn filters_entries_that_are_not_launchable_or_visible() {
        let temporary_directory = tempfile::tempdir().unwrap();
        let fixtures = [
            (
                "hidden.desktop",
                "[Desktop Entry]\nType=Application\nName=Hidden\nExec=hidden\nHidden=true\n",
            ),
            (
                "no-display.desktop",
                "[Desktop Entry]\nType=Application\nName=Internal\nExec=internal\nNoDisplay=true\n",
            ),
            (
                "link.desktop",
                "[Desktop Entry]\nType=Link\nName=Website\nURL=https://example.com\n",
            ),
            (
                "missing-exec.desktop",
                "[Desktop Entry]\nType=Application\nName=No Command\n",
            ),
        ];
        let files = fixtures
            .into_iter()
            .map(|(id, contents)| {
                let path = temporary_directory.path().join(id);
                fs::write(&path, contents).unwrap();
                DesktopFile {
                    id: id.to_owned(),
                    path,
                }
            })
            .collect::<Vec<_>>();

        let applications = load_applications_with_locales(&files, &[]);

        assert!(applications.is_empty());
    }
}
