# ADR 0003: Use JSON over a Unix socket

Newline-delimited JSON is easy to inspect during the prototype while preserving
a process boundary. It is local to the active user session via XDG runtime
storage.
