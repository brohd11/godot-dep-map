## Walks a dotted access path - `Singletons.Base`, `ALibRuntime.Utils.UFile` - to the file it
## actually names, by following `const NAME = preload("…")` declarations from file to file.
##
## Without this, `extends Singletons.Base` resolves only as far as its head, landing on the
## generated pseudo-namespace file. That file preloads every sibling, and the siblings refer
## back to it, so one unresolved dotted path manufactures a hub, a fan-out and a cycle that
## have nothing to do with the code's real shape.
##
## Text-only on purpose. UClassDetail.resolve_script_access_path() and UGDScript.Parser both
## do this properly, with inner classes and type inference - and both need a loaded GDScript,
## which would cost the collector its headless, never-load property. The `const X = preload()`
## shape covered here is what every namespace file in this project is made of.

const URegex = preload("uid://cpjnb72qn8bmh") # u_regex.gd
const UString = preload("uid://cwootkivqiwq1") # u_string.gd
const Resolve = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/resolve.gd")

const AUTOGEN_MARKER = "This file is auto-generated"
const AUTOGEN_SCAN_LINES = 3

static var _const_regex:RegEx


## Resolves `expression` as seen from `file_path`.
##
## `heads` is {name: path} for the file's own const preloads; the global class map is the
## fallback for the first segment. `cache` is {file_path: {const_name: target_path}}, shared
## across a scan - most of these files are being read anyway.
##
## Returns {"path", "partial", "consumed", "head_from_class_map"}. `partial` marks a walk that
## stopped early: the path is a real ancestor of what was asked for, not the thing itself, so a
## caller can choose to trust it less. `consumed` counts the leading segments that resolved to
## files, so `parts[consumed - 1]` names the file the walk landed on and `parts[consumed..]` is
## the unresolved tail - inner classes, enums, plain consts. `head_from_class_map` says the
## chain started at a global class rather than one of the file's own const preloads, which is
## what separates a namespace-style chain from a file's own local indirection. An unresolvable
## head gives "" and 0.
static func resolve(expression:String, heads:Dictionary, class_map:Dictionary, cache:Dictionary) -> Dictionary:
	var parts = expression.split(".", false)
	if parts.is_empty():
		return _unresolved()

	var from_class_map := false
	var current:String = heads.get(parts[0], "")
	if current == "":
		current = class_map.get(parts[0], "")
		from_class_map = current != ""
	if current == "":
		return _unresolved()

	for i in range(1, parts.size()):
		var consts = get_const_paths(current, cache)
		var next:String = consts.get(parts[i], "")
		if next == "":
			# an inner class, or a const that is not a preload - the last real file wins
			return {"path": current, "partial": true, "consumed": i, "head_from_class_map": from_class_map}
		current = next

	return {"path": current, "partial": false, "consumed": parts.size(), "head_from_class_map": from_class_map}


static func _unresolved() -> Dictionary:
	return {"path": "", "partial": false, "consumed": 0, "head_from_class_map": false}


## {const_name: resolved_path} for every `const X = preload("…")` in a file. Cached per scan.
static func get_const_paths(file_path:String, cache:Dictionary) -> Dictionary:
	if cache.has(file_path):
		return cache[file_path]

	var consts = {}
	cache[file_path] = consts
	if file_path == "" or file_path.get_extension().to_lower() != "gd":
		return consts

	var text = FileAccess.get_file_as_string(file_path)
	if text == "":
		return consts

	_ensure_regex()
	var map = UString.StringMap.new(text)
	var offset = 0
	for line in text.split("\n"):
		var m = _const_regex.search(line)
		if m != null and not _in_comment(map, offset + m.get_start()):
			var target = Resolve.to_path(m.get_string(3), file_path)
			if target != "":
				consts[m.get_string(1)] = target
		offset += line.length() + 1

	return consts


## Generated pseudo-namespace files announce themselves in their header. Marking edges into
## them lets a viewer skip the detour while a caller collecting files still keeps the file.
static func is_generated_namespace_file(file_path:String, cache:Dictionary) -> bool:
	var key = "autogen:" + file_path
	if cache.has(key):
		return cache[key]

	var result = false
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file != null:
		for _i in AUTOGEN_SCAN_LINES:
			if file.eof_reached():
				break
			if file.get_line().contains(AUTOGEN_MARKER):
				result = true
				break
	cache[key] = result
	return result


static func _ensure_regex() -> void:
	if _const_regex == null:
		_const_regex = RegEx.new()
		_const_regex.compile('^\\s*const\\s+([A-Za-z_]\\w*)\\s*(?::=|=)\\s*preload\\((["\'])(.+?)\\2\\)')
		# groups: 1 = const name, 2 = quote, 3 = path


static func _in_comment(map, index:int) -> bool:
	if index < 0 or index >= map.comment_mask.size():
		return false
	return map.comment_mask[index] == 1
