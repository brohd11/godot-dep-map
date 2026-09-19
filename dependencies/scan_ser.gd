## Text scanner for the serialized resource formats (.tscn/.tres). Reads [ext_resource] lines
## and the [gd_resource] script_class header. Sub-resources live in the file itself, so they
## are not dependencies.
##
## Attributes are read locally rather than through UPackedScene.ReadFile._get_slice_from_line,
## whose missing-attribute check is `if line.find(x):` - that is truthy on -1 and returns a
## garbage slice when the attribute is absent, which uid= frequently is.

const DepEdge = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/dep_edge.gd")
const Resolve = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/resolve.gd")

static func scan(file_path:String, ctx) -> Array:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return []

	var refs:Array = []
	var line_no = 0
	while not file.eof_reached():
		var line = file.get_line()
		line_no += 1
		if not line.begins_with("["):
			continue

		if line.begins_with("[ext_resource"):
			var ref = _ext_resource_ref(line, line_no)
			if not ref.is_empty():
				refs.append(ref)
			continue

		if line.begins_with("[gd_resource") or line.begins_with("[gd_scene"):
			var script_class = _attr(line, "script_class")
			if script_class == "":
				continue
			var path = ctx.class_map.get(script_class)
			if path == null:
				continue
			refs.append({
				"raw": script_class,
				"path": path,
				"kind": DepEdge.Kind.SCRIPT_CLASS,
				"line_no": line_no,
				"meta": {"class": script_class},
			})

	return refs


# uid= is authoritative when present - a moved file keeps its uid but not its path - and
# path= is the fallback for older files and for uids missing from the registry.
static func _ext_resource_ref(line:String, line_no:int) -> Dictionary:
	var uid = _attr(line, "uid")
	var path = _attr(line, "path")
	var raw := ""
	if uid != "" and Resolve.to_path(uid, "") != "":
		raw = uid
	elif path != "":
		raw = path
	elif uid != "":
		raw = uid
	else:
		return {}

	return {
		"raw": raw,
		"kind": DepEdge.Kind.EXT_RESOURCE,
		"line_no": line_no,
		"meta": {"type": _attr(line, "type"), "id": _attr(line, "id"), "path": path},
	}


## The leading space matters: without it, `id=` matches inside `uid=`.
static func _attr(line:String, key:String) -> String:
	var marker = ' %s="' % key
	var start = line.find(marker)
	if start == -1:
		return ""
	start += marker.length()
	var end = line.find('"', start)
	if end == -1:
		return ""
	return line.substr(start, end - start)
