extends StaticBody3D

var running := false
var backend: BackendClient

func interaction_prompt() -> String:
	return "[E] LAUNCH VISUAL STUDIO CODE" if not running else "VISUAL STUDIO CODE // RUNNING"

func interact() -> void:
	if running:
		return
	if not backend or not backend.launch_app("code.desktop"):
		print("Velora Core is disconnected; launch request was not sent")

func set_backend(client: BackendClient) -> void:
	backend = client
	backend.application_state_changed.connect(_on_application_state_changed)

func _on_application_state_changed(desktop_id: String, is_running: bool) -> void:
	if desktop_id == "code.desktop":
		running = is_running
