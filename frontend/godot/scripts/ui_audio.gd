extends Node
## Fixed generated cues and three reusable voices, never a playback queue.
const BUS := "VeloraUI"
const RATE := 22050
const VOICES := 3
const CUES := {"navigate": [520.0, 0.025], "interact": [660.0, 0.045], "confirm": [880.0, 0.055], "reject": [220.0, 0.075], "media": [740.0, 0.04]}
signal cue_played(kind: String)
var muted := false
var volume := 0.5
var output_available := false
var enabled := true
var _owns_bus := false
var _streams: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _voice := 0
var _last_kind := ""
var _last_usec := -1000000

func _ready() -> void:
	output_available = AudioServer.get_driver_name() != "Dummy"
	var index := AudioServer.get_bus_index(BUS)
	if index < 0:
		AudioServer.add_bus()
		index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, BUS)
		_owns_bus = true
	for kind in CUES: _streams[kind] = _generate(CUES[kind][0], CUES[kind][1])
	for _index in range(VOICES):
		var voice := AudioStreamPlayer.new()
		voice.bus = BUS
		add_child(voice)
		_voices.append(voice)
	configure(muted, volume)

func configure(next_muted: bool, next_volume: float) -> void:
	muted = next_muted
	volume = clampf(next_volume, 0, 1) if is_finite(next_volume) else 0.5
	var index := AudioServer.get_bus_index(BUS)
	if index >= 0:
		AudioServer.set_bus_mute(index, muted or volume <= 0)
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(volume, 0.00001)))
	if muted or volume <= 0:
		for voice in _voices: voice.stop()

func play_cue(kind: String) -> bool:
	if not enabled or muted or volume <= 0 or not output_available or not _streams.has(kind) or _voices.is_empty(): return false
	var now := Time.get_ticks_usec()
	if kind == _last_kind and now - _last_usec < 50000: return false
	_last_kind = kind
	_last_usec = now
	var voice := _voices[_voice]
	_voice = (_voice + 1) % VOICES
	voice.stop()
	voice.stream = _streams[kind]
	voice.play()
	cue_played.emit(kind)
	return true

func _exit_tree() -> void:
	for voice in _voices: voice.stop()
	var index := AudioServer.get_bus_index(BUS)
	if _owns_bus and index >= 0: AudioServer.remove_bus(index)

static func _generate(frequency: float, duration: float) -> AudioStreamWAV:
	var frames := int(RATE * duration)
	var bytes := PackedByteArray()
	bytes.resize(frames * 2)
	for index in range(frames):
		var phase := float(index) / frames
		# Gentle envelope and low amplitude; no abrupt click or looping asset.
		var sample := int(sin(TAU * frequency * index / RATE) * sin(PI * phase) * 3500)
		bytes.encode_s16(index * 2, sample)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = bytes
	return stream
