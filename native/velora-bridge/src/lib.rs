use godot::prelude::*;
use std::{
    io::{ErrorKind, Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
    },
    thread::{self, JoinHandle},
    time::Duration,
};
use velora_protocol::{MAX_MESSAGE_BYTES, default_socket_path};

const CHANNEL_CAPACITY: usize = 128;
const SOCKET_POLL_INTERVAL: Duration = Duration::from_millis(50);

struct VeloraExtension;

#[gdextension]
unsafe impl ExtensionLibrary for VeloraExtension {}

#[derive(GodotClass)]
#[class(base=Node)]
pub struct VeloraSocketBridge {
    base: Base<Node>,
    worker: Option<Worker>,
    socket_connected: bool,
}

#[godot_api]
impl INode for VeloraSocketBridge {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            worker: None,
            socket_connected: false,
        }
    }

    fn process(&mut self, _delta: f64) {
        while let Some(event) = self.next_event() {
            self.handle_event(event);
        }
    }

    fn exit_tree(&mut self) {
        self.stop_worker();
    }
}

#[godot_api]
impl VeloraSocketBridge {
    #[signal]
    fn socket_connected();

    #[signal]
    fn socket_disconnected(reason: GString);

    #[signal]
    fn line_received(payload: GString);

    #[signal]
    fn transport_error(code: GString, message: GString);

    #[func]
    fn default_socket_path(&mut self) -> GString {
        match default_socket_path() {
            Ok(path) => GString::from(path.to_string_lossy().as_ref()),
            Err(error) => {
                self.emit_transport_error("socket_path", &error.to_string());
                GString::new()
            }
        }
    }

    #[func]
    fn connect_socket(&mut self, path: GString) {
        self.stop_worker();
        let path = PathBuf::from(path.to_string());
        // Both directions are bounded. Shutdown uses a separate atomic flag so
        // it cannot be stranded behind queued frontend messages.
        let (command_sender, command_receiver) = mpsc::sync_channel(CHANNEL_CAPACITY);
        let (event_sender, event_receiver) = mpsc::sync_channel(CHANNEL_CAPACITY);
        let shutdown = Arc::new(AtomicBool::new(false));
        let worker_shutdown = Arc::clone(&shutdown);
        let join_handle = thread::Builder::new()
            .name("velora-socket".to_owned())
            .spawn(move || run_worker(path, command_receiver, event_sender, worker_shutdown));

        match join_handle {
            Ok(join_handle) => {
                self.worker = Some(Worker {
                    command_sender,
                    event_receiver,
                    shutdown,
                    join_handle: Some(join_handle),
                });
            }
            Err(error) => self.emit_transport_error("worker_start", &error.to_string()),
        }
    }

    #[func]
    fn disconnect_socket(&mut self) {
        self.stop_worker();
    }

    #[func]
    fn send_line(&mut self, payload: GString) -> bool {
        let payload = payload.to_string();
        if payload.contains('\n') {
            self.emit_transport_error("invalid_payload", "payload cannot contain a newline");
            return false;
        }
        if payload.len() > MAX_MESSAGE_BYTES {
            self.emit_transport_error("message_too_large", "payload exceeds 64 KiB");
            return false;
        }
        let Some(worker) = &self.worker else {
            return false;
        };
        match worker.command_sender.try_send(WorkerCommand::Send(payload)) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => {
                self.emit_transport_error("queue_full", "outbound IPC queue is full");
                false
            }
            Err(TrySendError::Disconnected(_)) => false,
        }
    }

    #[func]
    fn is_socket_connected(&self) -> bool {
        self.socket_connected
    }
}

impl VeloraSocketBridge {
    fn next_event(&self) -> Option<WorkerEvent> {
        let Some(worker) = &self.worker else {
            return None;
        };
        worker.event_receiver.try_recv().ok()
    }

    fn handle_event(&mut self, event: WorkerEvent) {
        match event {
            WorkerEvent::Connected => {
                self.socket_connected = true;
                self.base_mut().emit_signal("socket_connected", &[]);
            }
            WorkerEvent::Line(payload) => {
                self.base_mut()
                    .emit_signal("line_received", &[GString::from(&payload).to_variant()]);
            }
            WorkerEvent::Disconnected(reason) => {
                self.socket_connected = false;
                self.base_mut().emit_signal(
                    "socket_disconnected",
                    &[GString::from(&reason).to_variant()],
                );
            }
            WorkerEvent::Error { code, message } => {
                self.emit_transport_error(&code, &message);
            }
        }
    }

    fn emit_transport_error(&mut self, code: &str, message: &str) {
        self.base_mut().emit_signal(
            "transport_error",
            &[
                GString::from(code).to_variant(),
                GString::from(message).to_variant(),
            ],
        );
    }

    fn stop_worker(&mut self) {
        let Some(mut worker) = self.worker.take() else {
            return;
        };
        worker.shutdown.store(true, Ordering::Release);
        if let Some(join_handle) = worker.join_handle.take() {
            let _ = join_handle.join();
        }
        self.socket_connected = false;
    }
}

struct Worker {
    command_sender: SyncSender<WorkerCommand>,
    event_receiver: Receiver<WorkerEvent>,
    shutdown: Arc<AtomicBool>,
    join_handle: Option<JoinHandle<()>>,
}

impl Drop for VeloraSocketBridge {
    fn drop(&mut self) {
        self.stop_worker();
    }
}

enum WorkerCommand {
    Send(String),
}

enum WorkerEvent {
    Connected,
    Line(String),
    Disconnected(String),
    Error { code: String, message: String },
}

fn run_worker(
    path: PathBuf,
    command_receiver: Receiver<WorkerCommand>,
    event_sender: SyncSender<WorkerEvent>,
    shutdown: Arc<AtomicBool>,
) {
    let mut stream = match UnixStream::connect(&path) {
        Ok(stream) => stream,
        Err(error) => {
            send_event(
                &event_sender,
                &shutdown,
                WorkerEvent::Disconnected(format!("cannot connect to {}: {error}", path.display())),
            );
            return;
        }
    };
    if let Err(error) = stream.set_read_timeout(Some(SOCKET_POLL_INTERVAL)) {
        send_event(
            &event_sender,
            &shutdown,
            WorkerEvent::Error {
                code: "socket_configuration".to_owned(),
                message: error.to_string(),
            },
        );
        return;
    }
    send_event(&event_sender, &shutdown, WorkerEvent::Connected);
    let mut accumulator = LineAccumulator::default();
    let mut read_buffer = [0_u8; 4096];

    loop {
        if shutdown.load(Ordering::Acquire) {
            return;
        }
        loop {
            match command_receiver.try_recv() {
                Ok(WorkerCommand::Send(payload)) => {
                    if let Err(error) = stream
                        .write_all(payload.as_bytes())
                        .and_then(|_| stream.write_all(b"\n"))
                    {
                        send_event(
                            &event_sender,
                            &shutdown,
                            WorkerEvent::Disconnected(format!("socket write failed: {error}")),
                        );
                        return;
                    }
                }
                Err(TryRecvError::Disconnected) => return,
                Err(TryRecvError::Empty) => break,
            }
        }

        match stream.read(&mut read_buffer) {
            Ok(0) => {
                send_event(
                    &event_sender,
                    &shutdown,
                    WorkerEvent::Disconnected("core closed the socket".to_owned()),
                );
                return;
            }
            Ok(read) => match accumulator.push(&read_buffer[..read]) {
                Ok(lines) => {
                    for line in lines {
                        send_event(&event_sender, &shutdown, WorkerEvent::Line(line));
                    }
                }
                Err(message) => {
                    send_event(
                        &event_sender,
                        &shutdown,
                        WorkerEvent::Error {
                            code: "invalid_frame".to_owned(),
                            message: message.to_owned(),
                        },
                    );
                    return;
                }
            },
            Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(error) => {
                send_event(
                    &event_sender,
                    &shutdown,
                    WorkerEvent::Disconnected(format!("socket read failed: {error}")),
                );
                return;
            }
        }
    }
}

fn send_event(sender: &SyncSender<WorkerEvent>, shutdown: &AtomicBool, event: WorkerEvent) {
    let mut pending = event;
    loop {
        if shutdown.load(Ordering::Acquire) {
            return;
        }
        match sender.try_send(pending) {
            Ok(()) | Err(TrySendError::Disconnected(_)) => return,
            Err(TrySendError::Full(event)) => {
                pending = event;
                // Preserve protocol responses and transport lifecycle events
                // while still allowing shutdown to interrupt a saturated UI.
                thread::sleep(Duration::from_millis(1));
            }
        }
    }
}

#[derive(Default)]
struct LineAccumulator {
    bytes: Vec<u8>,
}

impl LineAccumulator {
    fn push(&mut self, chunk: &[u8]) -> Result<Vec<String>, &'static str> {
        let mut lines = Vec::new();
        for byte in chunk {
            if *byte == b'\n' {
                let line_bytes = std::mem::take(&mut self.bytes);
                let line = String::from_utf8(line_bytes).map_err(|_| "message is not UTF-8")?;
                lines.push(line);
            } else {
                self.bytes.push(*byte);
                if self.bytes.len() > MAX_MESSAGE_BYTES {
                    return Err("message exceeds 64 KiB");
                }
            }
        }
        Ok(lines)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assembles_partial_and_multiple_lines() {
        let mut accumulator = LineAccumulator::default();
        assert!(accumulator.push(b"one").unwrap().is_empty());
        assert_eq!(
            accumulator.push(b"\ntwo\n").unwrap(),
            vec!["one".to_owned(), "two".to_owned()]
        );
    }

    #[test]
    fn rejects_oversized_line() {
        let mut accumulator = LineAccumulator::default();
        assert!(
            accumulator
                .push(&vec![b'x'; MAX_MESSAGE_BYTES + 1])
                .is_err()
        );
    }
}
