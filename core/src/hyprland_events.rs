//! Typed parsing of Hyprland event-socket lines. Events are invalidation
//! hints only: they never build state, they only request a fresh snapshot.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionEvent {
    WorkspaceChanged,
    FocusedMonitorChanged,
    WindowOpened,
    WindowClosed,
    WindowMoved,
    ActiveWindowChanged,
}

const MAX_EVENT_LINE_BYTES: usize = 512;
const EVENT_SEPARATOR: char = '>';

/// Parse one `event>>payload` line. Unknown event kinds are ignored by
/// returning None; malformed or oversized lines are ignored as well, which
/// keeps duplicate or hostile input harmless.
pub(crate) fn parse_event_line(line: &str) -> Option<SessionEvent> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    if line.is_empty() || line.len() > MAX_EVENT_LINE_BYTES {
        return None;
    }

    let (kind, _payload) = line.split_once(EVENT_SEPARATOR)?;
    if !line[kind.len()..].starts_with(">>") {
        return None;
    }

    match kind {
        "workspace" | "activespecial" => Some(SessionEvent::WorkspaceChanged),
        "focusedmon" | "monitoradded" => Some(SessionEvent::FocusedMonitorChanged),
        "openwindow" => Some(SessionEvent::WindowOpened),
        "closenwindow" | "closewindow" => Some(SessionEvent::WindowClosed),
        "movewindow" | "movewindowv2" => Some(SessionEvent::WindowMoved),
        "activewindow" | "activewindowv2" => Some(SessionEvent::ActiveWindowChanged),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_required_event_kind() {
        assert_eq!(
            parse_event_line("workspace>>2"),
            Some(SessionEvent::WorkspaceChanged)
        );
        assert_eq!(
            parse_event_line("workspace>>special:magic"),
            Some(SessionEvent::WorkspaceChanged)
        );
        assert_eq!(
            parse_event_line("activespecial>>special:magic,eDP-1"),
            Some(SessionEvent::WorkspaceChanged)
        );
        assert_eq!(
            parse_event_line("focusedmon>>eDP-1,2"),
            Some(SessionEvent::FocusedMonitorChanged)
        );
        assert_eq!(
            parse_event_line("openwindow>>0x55f0aaaa,1,code,Editor"),
            Some(SessionEvent::WindowOpened)
        );
        assert_eq!(
            parse_event_line("closenwindow>>0x55f0aaaa"),
            Some(SessionEvent::WindowClosed)
        );
        assert_eq!(
            parse_event_line("closewindow>>0x55f0aaaa"),
            Some(SessionEvent::WindowClosed)
        );
        assert_eq!(
            parse_event_line("movewindow>>0x55f0aaaa,3"),
            Some(SessionEvent::WindowMoved)
        );
        assert_eq!(
            parse_event_line("movewindowv2>>0x55f0aaaa,3"),
            Some(SessionEvent::WindowMoved)
        );
        assert_eq!(
            parse_event_line("activewindow>>,"),
            Some(SessionEvent::ActiveWindowChanged)
        );
        assert_eq!(
            parse_event_line("activewindow>>code,Editor"),
            Some(SessionEvent::ActiveWindowChanged)
        );
        assert_eq!(
            parse_event_line("activewindowv2>>0x55f0aaaa"),
            Some(SessionEvent::ActiveWindowChanged)
        );
    }

    #[test]
    fn ignores_unknown_malformed_and_oversized_lines() {
        assert_eq!(parse_event_line("configreloaded>>"), None);
        assert_eq!(parse_event_line("somerandomevent>>payload"), None);
        assert_eq!(parse_event_line(""), None);
        assert_eq!(parse_event_line("\n"), None);
        assert_eq!(parse_event_line("no separator here"), None);
        assert_eq!(parse_event_line("workspace>single"), None);
        assert_eq!(
            parse_event_line(&format!("workspace>>{}", "x".repeat(600))),
            None
        );
    }

    #[test]
    fn duplicates_are_parsed_identically_and_stay_harmless() {
        let first = parse_event_line("openwindow>>0x55f0aaaa,1,code,Editor");
        let second = parse_event_line("openwindow>>0x55f0aaaa,1,code,Editor");
        assert_eq!(first, second);
    }
}
