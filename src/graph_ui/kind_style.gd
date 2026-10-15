## Colours and labels for DepEdge.Kind, plus file-type icon lookup.
##
## The palette is fixed rather than pulled from the editor theme: eight kinds have to stay
## apart from each other in both light and dark, which a theme's handful of accent colours
## cannot promise. Icons DO come from the editor theme, and degrade to null off-editor.

const DepEdge = preload("res://addons/_lib/dep_map/src/scanner/dep_edge.gd")

const Kind = DepEdge.Kind

## Indexed by Kind. `short` is what fits on a GraphNode row.
const STYLES:Array[Dictionary] = [
	{"color": Color("4dd0c4"), "label": "preload",      "short": "preload"},
	{"color": Color("f0a35e"), "label": "load",         "short": "load"},
	{"color": Color("b07de0"), "label": "extends",      "short": "extends"},
	{"color": Color("b07de0"), "label": "extends class","short": "extends"},
	{"color": Color("7bc96f"), "label": "global class", "short": "class"},
	{"color": Color("e3c76a"), "label": "ext_resource", "short": "ext_res"},
	{"color": Color("e07db0"), "label": "script_class", "short": "script"},
	{"color": Color("9aa0a6"), "label": "tag",          "short": "tag"},
]

const UNRESOLVED_COLOR = Color("e05a5a")
const MISSING_COLOR = Color("e05a5a")
const ROOT_COLOR = Color("6aa9e3")
const MUTED_COLOR = Color("8a8f94")

## Cycled by directory depth, so a column of frames shares one shade. Low alpha - a frame is a
## backdrop, not a thing to read.
const FOLDER_TINTS:Array[Color] = [
	Color(0.35, 0.52, 0.68, 0.16),
	Color(0.45, 0.62, 0.42, 0.16),
	Color(0.62, 0.48, 0.68, 0.16),
	Color(0.70, 0.58, 0.38, 0.16),
	Color(0.68, 0.44, 0.48, 0.16),
	Color(0.38, 0.62, 0.62, 0.16),
]


static func get_folder_tint(index:int) -> Color:
	return FOLDER_TINTS[index % FOLDER_TINTS.size()]

const ICON_BY_EXTENSION = {
	"gd": "GDScript",
	"cs": "CSharpScript",
	"tscn": "PackedScene",
	"scn": "PackedScene",
	"tres": "Resource",
	"res": "Resource",
	"png": "ImageTexture",
	"svg": "ImageTexture",
	"jpg": "ImageTexture",
	"webp": "ImageTexture",
	"ttf": "FontFile",
	"otf": "FontFile",
	"wav": "AudioStreamWAV",
	"ogg": "AudioStreamOggVorbis",
	"mp3": "AudioStreamMP3",
	"json": "TextFile",
	"txt": "TextFile",
	"md": "TextFile",
	"cfg": "ConfigFile",
	"yml": "TextFile",
	"yaml": "TextFile",
}

const FALLBACK_ICON = "File"


static func get_style(kind:int) -> Dictionary:
	if kind < 0 or kind >= STYLES.size():
		return {"color": MUTED_COLOR, "label": "unknown", "short": "?"}
	return STYLES[kind]


static func get_color(kind:int) -> Color:
	return get_style(kind).color


static func get_short(kind:int) -> String:
	return get_style(kind).short


static func get_label(kind:int) -> String:
	return get_style(kind).label


## Editor icon for a file, or null outside the editor.
static func get_file_icon(path:String):
	var theme = _get_editor_theme()
	if theme == null:
		return null
	var icon_name:String = ICON_BY_EXTENSION.get(path.get_extension().to_lower(), FALLBACK_ICON)
	if not theme.has_icon(icon_name, &"EditorIcons"):
		icon_name = FALLBACK_ICON
	if not theme.has_icon(icon_name, &"EditorIcons"):
		return null
	return theme.get_icon(icon_name, &"EditorIcons")


static func get_editor_icon(icon_name:String):
	var theme = _get_editor_theme()
	if theme == null or not theme.has_icon(icon_name, &"EditorIcons"):
		return null
	return theme.get_icon(icon_name, &"EditorIcons")


## Editor UI scale, 1.0 when there is no editor.
static func get_scale() -> float:
	var ed_int = get_editor_interface()
	if ed_int != null:
		return ed_int.get_editor_scale()
	return 1.0


## is_editor_hint() first, not has_singleton(): the EditorInterface singleton is registered
## even in a headless run, where fetching it only produces an engine error and a null.
static func get_editor_interface():
	if not Engine.is_editor_hint():
		return null
	var ed_int = Engine.get_singleton(&"EditorInterface")
	return ed_int if is_instance_valid(ed_int) else null


static func _get_editor_theme():
	var ed_int = get_editor_interface()
	if ed_int == null:
		return null
	return ed_int.get_editor_theme()
