## Walks a dotted access path - `Singletons.Base`, `ALibRuntime.Utils.UFile` - to the file it
## actually names, following `const` declarations from file to file: preloads, and aliases such
## as `const UFile = UtilsRemote.UFile`, each read in the scope of the file declaring it.
##
## Without this, a dotted path resolves only as far as its head, so one reference manufactures
## a hub, a fan-out and a cycle that have nothing to do with the code's real shape.
##
## Text-only on purpose: UClassDetail and UGDScript.Parser need a loaded GDScript, which would
## cost the collector its headless, never-load property.

const URegex = preload("uid://d0rbf4as6kpns") #! resolve UtilR.Strings.URegex
const StringMap = preload("uid://btml0a8r6vbbn") #! resolve UtilR.Strings.StringMap
const Resolve = preload("res://addons/_lib/dep_map/src/scanner/resolve.gd")

const AUTOGEN_MARKER = "This file is auto-generated"
const AUTOGEN_SCAN_LINES = 3

static var _const_regex:RegEx
static var _alias_regex:RegEx
static var _literal_regex:RegEx
static var _extends_regex:RegEx


## Resolves `expression` as seen from `from_file`.
##
## `heads` is {name: path} for consts `from_file` alone can see, such as a function-local one;
## the file's own and inherited consts come first and the global class map is the fallback.
## `cache` is shared across a scan.
##
## Returns {"path", "partial", "consumed", "head_from_class_map", "head_path", "suffix",
## "bind_name", "crossed"}. `partial` marks a path that is a real ancestor of what was asked for.
## `consumed` counts the leading segments that resolved, and `parts[consumed..]` is the tail.
## `suffix` is what an alias added past the landing file (`const Foo = Other.Inner` gives
## ["Inner"]), so the expression reads as `bind_name` + suffix + tail. `crossed` holds each const
## the walk went through as {"file", "name", "path"}. `literal` is the source text when the whole
## expression boils down to a plain value. An unresolvable head gives "" and 0.
static func resolve(expression:String, heads:Dictionary, class_map:Dictionary, cache:Dictionary, from_file:String = "") -> Dictionary:
	var parts = expression.split(".", false)
	if parts.is_empty():
		return _unresolved()

	var from_class_map := false
	var state := {}
	if from_file != "":
		state = _member(from_file, parts[0], class_map, cache, {})
	if state.is_empty() and heads.has(parts[0]):
		state = _state(heads[parts[0]], parts[0])
	if state.is_empty() and class_map.get(parts[0], "") != "":
		from_class_map = true
		state = _state(class_map[parts[0]], parts[0])
	if state.is_empty():
		return _unresolved()

	var head_path:String = state.path
	var consumed = 1
	while consumed < parts.size() and state.suffix.is_empty():
		var next = _member(state.path, parts[consumed], class_map, cache, {})
		if next.is_empty():
			break # an inner class, or a const that is not a file - the last real file wins
		next.crossed = state.crossed + next.crossed
		state = next
		consumed += 1

	if state.literal != "" and consumed < parts.size():
		# a member of a value: the file still has to be there to hold it
		state.suffix = [parts[consumed - 1]]
		state.bind = _file_bind_name(state.path)
		state.literal = ""

	return {
		"path": state.path,
		"partial": consumed < parts.size() or not state.suffix.is_empty(),
		"consumed": consumed,
		"head_from_class_map": from_class_map,
		"head_path": head_path,
		"suffix": state.suffix,
		"bind_name": state.bind,
		"crossed": state.crossed,
		"literal": state.literal,
	}


static func _unresolved() -> Dictionary:
	return {"path": "", "partial": false, "consumed": 0, "head_from_class_map": false,
		"head_path": "", "suffix": [], "bind_name": "", "crossed": [], "literal": ""}


static func _state(path:String, bind:String) -> Dictionary:
	return {"path": path, "suffix": [], "bind": bind, "crossed": [], "literal": ""}


## Where `file.name` lands, or {} when `name` is no const of `file` or its ancestors. `visiting`
## holds the chain being walked: hubs preload each other, so a cycle is an ordinary input.
static func _member(file_path:String, name:String, class_map:Dictionary, cache:Dictionary, visiting:Dictionary) -> Dictionary:
	var key = file_path + "::" + name
	if visiting.has(key):
		return {}
	visiting[key] = true
	var state = _member_state(file_path, name, class_map, cache, visiting)
	visiting.erase(key)
	return state


static func _member_state(file_path:String, name:String, class_map:Dictionary, cache:Dictionary, visiting:Dictionary) -> Dictionary:
	var entry = get_const_entries(file_path, cache).get(name)
	if entry == null or entry.indented:
		var base = get_base_file(file_path, class_map, cache)
		return {} if base == "" else _member(base, name, class_map, cache, visiting)

	if entry.has("literal"):
		var value = _state(file_path, name)
		value.literal = entry.literal
		value.crossed = [{"file": file_path, "name": name, "path": file_path}]
		return value

	var state := {}
	var segments:Array = []
	if entry.has("path"):
		segments = entry.rest
		# a `preload("a.gd").Inner` const cannot share its name with a binding of a.gd itself
		var bind = name if segments.is_empty() else _file_bind_name(entry.path)
		state = _state(entry.path, bind)
	else:
		var parts = entry.expr.split(".", false)
		state = _member(file_path, parts[0], class_map, cache, visiting)
		if state.is_empty() and class_map.get(parts[0], "") != "":
			state = _state(class_map[parts[0]], parts[0])
		if state.is_empty():
			return {} # an engine class or a literal - not a file this walk can place
		segments = parts.slice(1)

	for segment:String in segments:
		var next = {} if not state.suffix.is_empty() else _member(state.path, segment, class_map, cache, visiting)
		if next.is_empty():
			state.suffix = state.suffix + [segment]
		else:
			next.crossed = state.crossed + next.crossed
			state = next

	state.crossed = [{"file": file_path, "name": name, "path": state.path}] + state.crossed
	return state


static func _file_bind_name(path:String) -> String:
	return path.get_file().get_basename().to_pascal_case()


## {const_name: resolved_path} for every plain `const X = preload("…")` in a file.
static func get_const_paths(file_path:String, cache:Dictionary) -> Dictionary:
	var consts = {}
	var entries = get_const_entries(file_path, cache)
	for name:String in entries:
		if entries[name].has("path") and entries[name].rest.is_empty():
			consts[name] = entries[name].path
	return consts


## Const names `file_path` inherits and can resolve to a file, as {name: declaring_file}. The
## nearest ancestor wins and the file's own names are left out.
static func get_inherited_consts(file_path:String, class_map:Dictionary, cache:Dictionary) -> Dictionary:
	var own = get_const_entries(file_path, cache)
	var out = {}
	var seen = {file_path: true}
	var base = get_base_file(file_path, class_map, cache)
	while base != "" and not seen.has(base):
		seen[base] = true
		var entries = get_const_entries(base, cache)
		for name:String in entries:
			if not entries[name].indented and not own.has(name) and not out.has(name):
				out[name] = base
		base = get_base_file(base, class_map, cache)
	return out


## The script `file_path` extends, or "" for an engine class. Text-only, like the walk.
static func get_base_file(file_path:String, class_map:Dictionary, cache:Dictionary) -> String:
	var key = "base:" + file_path
	if cache.has(key):
		return cache[key]
	cache[key] = "" # an `extends` head is looked up through this very function
	get_const_entries(file_path, cache)
	var raw:String = cache.get("extends:" + file_path, "")
	var base := ""
	if raw.begins_with('"') or raw.begins_with("'"):
		base = Resolve.to_path(raw.substr(1, raw.length() - 2), file_path)
	elif raw != "":
		var result = resolve(raw, {}, class_map, cache, file_path)
		if not result.partial:
			base = result.path
	cache[key] = base
	return base


## {const_name: entry} for a file. An entry is {"path", "rest", "line", "indented"} for a preload,
## `rest` being the segments after it in `preload("a.gd").Inner`, {"expr", ...} for an alias, or
## {"literal", ...} for a plain value. The last two are class-scope only, and a typed literal is
## left out because its value is not what its text says: `const X:float = 1` inlines as an int.
static func get_const_entries(file_path:String, cache:Dictionary) -> Dictionary:
	var key = "entries:" + file_path
	if cache.has(key):
		return cache[key]

	var entries = {}
	cache[key] = entries
	if file_path == "" or file_path.get_extension().to_lower() != "gd":
		return entries

	var text = FileAccess.get_file_as_string(file_path)
	if text == "":
		return entries

	_ensure_regex()
	var map = StringMap.new(text)
	var offset = 0
	var line_no = 0
	for line in text.split("\n"):
		line_no += 1
		var m = _const_regex.search(line)
		if m != null and not _masked(map, offset + m.get_start(2)):
			var indented = m.get_string(1) != ""
			var target = Resolve.to_path(m.get_string(4), file_path)
			if target != "" and not (indented and entries.has(m.get_string(2))):
				entries[m.get_string(2)] = {"path": target, "line": line_no, "indented": indented,
					"rest": Array(m.get_string(5).split(".", false))}
		else:
			var literal = _literal_regex.search(line)
			var alias = _alias_regex.search(line)
			if literal != null and not _masked(map, offset + literal.get_start(1)):
				entries[literal.get_string(1)] = {"literal": literal.get_string(2), "line": line_no, "indented": false}
			elif alias != null and not _masked(map, offset + alias.get_start(1)):
				entries[alias.get_string(1)] = {"expr": alias.get_string(2), "line": line_no, "indented": false}
			elif not cache.has("extends:" + file_path):
				var base = _extends_regex.search(line)
				if base != null and not _masked(map, offset + base.get_start()):
					cache["extends:" + file_path] = base.get_string(1)
		offset += line.length() + 1

	return entries


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
	if _const_regex != null:
		return
	var type_hint = "(?::\\s*[\\w.]+\\s*)?"
	_const_regex = RegEx.new()
	_const_regex.compile('^(\\s*)const\\s+([A-Za-z_]\\w*)\\s*' + type_hint + '(?::=|=)\\s*preload\\((["\'])(.+?)\\3\\)((?:\\.[A-Za-z_]\\w*)*)\\s*(?:#.*)?$')
	# groups: 1 = indent, 2 = const name, 3 = quote, 4 = path, 5 = trailing segments
	_alias_regex = RegEx.new()
	_alias_regex.compile('^const\\s+([A-Za-z_]\\w*)\\s*' + type_hint + '(?::=|=)\\s*([A-Za-z_]\\w*(?:\\.[A-Za-z_]\\w*)*)\\s*(?:#.*)?$')
	_literal_regex = RegEx.new()
	_literal_regex.compile('^const\\s+([A-Za-z_]\\w*)\\s*(?::=|=)\\s*(-?\\d[\\d_]*(?:\\.\\d+)?|true|false|null|&?"(?:[^"\\\\]|\\\\.)*"|&?\'(?:[^\'\\\\]|\\\\.)*\')\\s*(?:#.*)?$')
	_extends_regex = RegEx.new()
	_extends_regex.compile('^(?:class_name\\s+\\w+\\s+)?extends\\s+("[^"]+"|\'[^\']+\'|[A-Za-z_][\\w.]*)')


static func _masked(map, index:int) -> bool:
	if index < 0 or index >= map.comment_mask.size():
		return false
	return map.index_in_string_or_comment(index)
