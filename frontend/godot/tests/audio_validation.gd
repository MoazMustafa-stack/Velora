extends SceneTree
const Audio = preload("res://scripts/ui_audio.gd")
var failed := false
func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var before := AudioServer.get_bus_volume_db(0)
	var audio := Audio.new()
	root.add_child(audio)
	check(audio._streams.size() == 5 and audio._voices.size() == 3, "Audio assets/voices are fixed and bounded")
	for stream in audio._streams.values():
		check(stream.mix_rate == 22050 and stream.data.size() < 4000 and stream.loop_mode == AudioStreamWAV.LOOP_DISABLED, "Cues are small, finite generated PCM assets")
	check(not audio.play_cue("missing"), "Missing cue is a silent no-op")
	audio.output_available = false
	check(not audio.play_cue("confirm"), "Unavailable device is a silent no-op")
	audio.output_available = true # Dummy backend exercises player/bus logic silently.
	check(audio.play_cue("confirm"), "Known local cue plays")
	audio.configure(true, 0.8)
	check(not audio.play_cue("reject") and audio._voices.all(func(voice): return not voice.playing), "Mute stops all active voices and future cues")
	audio.configure(false, 0.0)
	check(not audio.play_cue("reject"), "Zero volume is silent")
	audio.configure(false, 8.0)
	check(audio.volume == 1.0 and AudioServer.get_bus_volume_db(0) == before, "Volume is bounded without changing Master")
	audio.queue_free()
	await process_frame
	check(AudioServer.get_bus_index(Audio.BUS) == -1, "Audio owns and cleans up only its local bus")
	if not failed: print("D6.10 bounded local audio validation passed")
	quit(1 if failed else 0)
