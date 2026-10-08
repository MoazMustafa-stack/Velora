extends CanvasLayer
const Shell = preload("res://ui/panel_shell.gd")
const Tokens = preload("res://ui/design_tokens.gd")
const Actions = preload("res://scripts/input_actions.gd")
const MetricStatus = preload("res://ui/telemetry_status.gd")
signal observatory_closed
var _shell: RefCounted
var _rows: Array[Dictionary] = []
var _snapshot: Dictionary = {}
var availability := "waiting"
var core_online := false

func _ready() -> void:
	visible = false
	_shell = Shell.new(self, Tokens.PANEL_POSITION, Vector2(Tokens.PANEL_WIDTH, 0), 4, false)
	for _index in range(4): _rows.append(Shell.row(_shell.box))
	_shell.finish("")
	refresh()

func open() -> void:
	visible = true
	refresh()

func close() -> void:
	visible = false
	observatory_closed.emit()

func set_core_online(online: bool) -> void:
	core_online = online
	refresh()

func set_availability(state: String) -> void:
	availability = state
	refresh()

func update_snapshot(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	refresh()

func refresh() -> void:
	if _shell == null: return
	var live := core_online and availability == "available"
	_shell.title.text = "OBSERVATORY // " + ("LIVE" if live else "CORE OFFLINE" if not core_online else availability.to_upper())
	_shell.title.add_theme_color_override("font_color", Tokens.READY if live else Tokens.WAITING)
	_shell.hint.text = Actions.binding_label("back") + " BACK // SYSTEM DATA IS NOT SAVED"
	for row in _rows:
		row.summary.text = ""
		row.detail.text = ""
	if _snapshot.is_empty():
		_rows[0].summary.text = "NO TELEMETRY SAMPLE"
		_rows[0].detail.text = "START CORE // CHECK TELEMETRY POLICY" if not live else "WAIT FOR THE NEXT SAMPLE"
		return
	var cpu: Dictionary = _snapshot.get("cpu", {})
	var memory: Dictionary = _snapshot.get("memory", {})
	var disk: Dictionary = _snapshot.get("disk", {})
	var network: Dictionary = _snapshot.get("network", {})
	var prefix := "" if live else "STALE // "
	var cpu_state := MetricStatus.label(cpu, "utilization_basis_points")
	var memory_state := MetricStatus.label(memory)
	var disk_state := MetricStatus.label(disk)
	var network_state := MetricStatus.label(network)
	_rows[0].summary.text = prefix + "CPU // " + (cpu_state if not cpu_state.is_empty() else "%.1f%%" % (float(cpu.utilization_basis_points) / 100))
	_rows[0].detail.text = "LOCAL SAMPLE // NO PROCESS CONTENT"
	_rows[1].summary.text = "MEMORY // " + (memory_state if not memory_state.is_empty() else "%d / %d MiB" % [int(memory.get("used_bytes", 0)) / 1048576, int(memory.get("total_bytes", 0)) / 1048576])
	_rows[1].detail.text = "RAM // AGGREGATE ONLY"
	_rows[2].summary.text = "DISK // " + (disk_state if not disk_state.is_empty() else "READ %d  WRITE %d B/s" % [disk.get("read_bytes_per_second", 0), disk.get("write_bytes_per_second", 0)])
	_rows[2].detail.text = "ACTIVITY // NOT DISK CAPACITY"
	_rows[3].summary.text = "NETWORK // " + (network_state if not network_state.is_empty() else "RX %d  TX %d B/s" % [network.get("receive_bytes_per_second", 0), network.get("transmit_bytes_per_second", 0)])
	_rows[3].detail.text = "TRAFFIC RATE // NO NETWORK CONTENT"
