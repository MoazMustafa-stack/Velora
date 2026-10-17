extends RefCounted
## Semantic palette and fixed-canvas geometry. Root values remain the legacy
## runtime contract until the reviewed workshop replaces it, not a theme toggle.

const CANVAS := Vector2i(320, 180)
const TILE_SIZE := Vector2i(16, 16)
const SPACE := 4
const FONT_BODY := 7
const FONT_TITLE := 8
const READY := Color("9af4e7")
const WAITING := Color("f5b943")
const FAILURE := Color("e05a67")
const TEXT := Color("dce4f0")
const MUTED := Color("586a80")
const SURFACE := Color("0c1c33")
const SELECTED := Color("16324f")
const PANEL := Color("071226")
const SHADE := Color(0.027451, 0.039216, 0.07451, 0.901961)
const TONES := {"ready": READY, "waiting": WAITING, "failure": FAILURE}
const STATUS_MARKERS := {
	"ready": ["....#", "...#.", "#.#..", ".#...", "....."],
	"attention": ["..#..", "..#..", "..#..", ".....", "..#.."],
	"offline": ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
}
const PANEL_POSITION := Vector2(40, 24)
const PANEL_WIDTH := 240
const MAP_POSITION := Vector2(40, 30)
const MAP_MINIMUM := Vector2(240, 110)

const WORLD_BACKGROUND := Color("0b1020")
const WORLD_FLOOR := Color("17233b")
const WORLD_FLOOR_LIGHT := Color("1d2c49")
const WORLD_STEEL := Color("293858")
const WORLD_STEEL_LIGHT := Color("41577c")
const WORLD_ACCENT := Color("41d6c3")
const WORLD_AMBER := Color("f5b942")
const WORLD_TEXT := Color("dce6f2")
const WORLD_SHADOW := Color("070a13")

## Approved density; proposed visual system. R6.02 contact-sheet review precedes
## production world migration. All lengths here are native UI pixels, not physics.
class Workshop:
	const CANVAS := Vector2i(640, 360)
	const WORLD_VIEW := Vector2i(320, 128)
	const HEADER := Rect2i(0, 0, 640, 24)
	const WORLD := Rect2i(0, 24, 640, 256)
	const INSPECTOR := Rect2i(0, 280, 640, 80)
	const SPACE := 8
	const FONT_BODY := 12
	const FONT_TITLE := 14
	const OUTLINE_WIDTH := 1
	const FOCUS_WIDTH := 2
	const BACKGROUND := Color("15172b")
	const PANEL := Color("252236")
	const SURFACE := Color("30304a")
	const OUTLINE := Color("776477")
	const TEXT := Color("f4e3d5")
	const MUTED := Color("b5abc1")
	const ACCENT := Color("ffcb85")
	const FOCUS := Color("ffe1a7")
	const READY := Color("9ce4dc")
	const WAITING := Color("e5c27f")
	const FAILURE := Color("f39b9d")
	const DISABLED := Color("b0a5b9")
	const FLOOR := Color("302c43")
	const FLOOR_LIGHT := Color("343047")
	const WALL := Color("60546e")
	const WALL_LIGHT := Color("78647b")
	const SHADOW := Color("151326")
	const WOOD := Color("8b6a66")
	const WOOD_DARK := Color("5e4f67")
	const BRASS := Color("b9a591")
	const STATUS_MARKERS := {
		"ready": ["....#", "...#.", "#.#..", ".#...", "....."],
		"waiting": ["#####", ".#.#.", "..#..", ".#.#.", "#####"],
		"failure": ["..#..", "..#..", "..#..", ".....", "..#.."],
		"offline": ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
		"disabled": [".....", ".....", "#####", ".....", "....."],
	}
