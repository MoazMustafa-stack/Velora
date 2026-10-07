# Local UI cues

Velora generates its five UI cues locally in `scripts/ui_audio.gd`: short,
low-amplitude sine tones with an attack/decay envelope. There are no downloaded
recordings, external services, live-data sonification, microphone capture or
system mixer commands. The generator is original project code, covered by the
repository's BSD-3-Clause license; no third-party audio attribution is required.

Five fixed cached mono 16-bit PCM streams at 22050 Hz feed three reusable voices
on the app-local `VeloraUI` bus. There is no unbounded playback queue. Repeat
cues are rate-limited. Mute stops active voices immediately; zero volume is
silent. A dummy/missing audio device and unknown cue are silent no-ops.

The stream contract follows Godot's [AudioStreamWAV documentation](https://docs.godotengine.org/en/stable/classes/class_audiostreamwav.html).
