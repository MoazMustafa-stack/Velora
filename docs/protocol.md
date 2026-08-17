# Protocol

The frontend and core communicate over `$XDG_RUNTIME_DIR/velora.sock` (or
`/tmp/velora-$UID.sock`) using one JSON object per newline. Protocol version
is currently `1`.

```json
{"protocol_version":1,"type":"ping"}
{"protocol_version":1,"type":"launch_app","desktop_id":"code.desktop"}
```

```json
{"protocol_version":1,"type":"pong"}
{"protocol_version":1,"type":"application_state","desktop_id":"code.desktop","running":true}
```

Invalid messages and unsupported versions receive an `error` response. The
core does not expose a shell-command request; desktop IDs are explicitly
validated by the launcher.
