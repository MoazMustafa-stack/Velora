extends RefCounted
## Concise causes and next actions. Never include raw backend logs or content.

static func describe(topic: String, state: String) -> Dictionary:
	if state == "offline":
		return {"title": "CORE OFFLINE", "detail": "START CORE // AUTO RECONNECT", "tone": "failure"}
	match topic + ":" + state:
		"notifications:disabled":
			return {"title": "NOTIFICATIONS DISABLED", "detail": "OPT IN WHEN STARTING CORE", "tone": "waiting"}
		"notifications:restricted":
			return {"title": "MONITOR RESTRICTED", "detail": "SESSION BUS DENIED ACCESS", "tone": "failure"}
		"notifications:unavailable":
			return {"title": "FEED UNAVAILABLE", "detail": "CHECK CORE // REOPEN TO RETRY", "tone": "failure"}
		"notifications:available":
			return {"title": "NO NOTIFICATIONS", "detail": "FEED READY // WAIT FOR AN EVENT", "tone": "ready"}
		"media:unavailable":
			return {"title": "MEDIA UNAVAILABLE", "detail": "CHECK CORE // REOPEN TO RETRY", "tone": "failure"}
		"media:available":
			return {"title": "NO PLAYERS", "detail": "OPEN AN MPRIS MEDIA PLAYER", "tone": "ready"}
		"workspaces:unavailable":
			return {"title": "NO HYPRLAND SESSION", "detail": "RUN INSIDE HYPRLAND", "tone": "failure"}
		"workspaces:incompatible":
			return {"title": "HYPRLAND INCOMPATIBLE", "detail": "CHECK THE SUPPORTED VERSION", "tone": "failure"}
		"workspaces:available":
			return {"title": "NO WORKSPACES", "detail": "OPEN A WORKSPACE IN HYPRLAND", "tone": "ready"}
		"registry:available":
			return {"title": "NO APPLICATIONS", "detail": "CHECK INSTALLED DESKTOP ENTRIES", "tone": "waiting"}
	return {"title": "WAITING FOR " + topic.to_upper(), "detail": "WAIT // REOPEN TO RETRY", "tone": "waiting"}
