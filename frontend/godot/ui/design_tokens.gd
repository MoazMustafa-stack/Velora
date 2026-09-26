extends RefCounted
## Semantic palette and fixed-canvas geometry. World variants deliberately
## retain their original values; this foundation does not recolor the art.

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
