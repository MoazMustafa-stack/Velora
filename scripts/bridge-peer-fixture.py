"""Test-only Unix peer: accepts one connection but deliberately never reads."""
import pathlib
import signal
import socket
import sys
import threading

directory = pathlib.Path(sys.argv[1])
path = directory / "peer.sock"
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
peer = None
queued = []
try:
    listener.bind(str(path))
    mode = sys.argv[2] if len(sys.argv) > 2 else "write"
    listener.listen(1)
    listener.settimeout(0.2)
    if mode == "backlog":
        # Fill the Unix listen queue without accepting any connection.
        for _ in range(2):
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(0.2)
            connection.connect(str(path))
            queued.append(connection)
        (directory / "ready").touch()
        stop.wait()
    while mode == "write" and not stop.is_set() and peer is None:
        try:
            peer, _ = listener.accept()
        except socket.timeout:
            continue
    if peer is not None:
        stop.wait()
finally:
    for connection in queued:
        connection.close()
    if peer is not None:
        peer.close()
    listener.close()
    path.unlink(missing_ok=True)
