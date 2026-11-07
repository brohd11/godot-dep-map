## Text scanner for .gd files. Emits unresolved refs; scanner.gd resolves and places them.
## One StringMap per file masks strings and comments, so a `preload(` inside either is ignored
## without resorting to counting quotes on the line.

const StringMap = preload("uid://btml0a8r6vbbn") #! resolve UtilR.Strings.StringMap
const URegex = preload("uid://d0rbf4as6kpns") #! resolve UtilR.Strings.URegex
const DepEdge = preload("res://addons/_lib/dep_map/src/scanner/dep_edge.gd")
const Resolve = preload("res://addons/_lib/dep_map/src/scanner/resolve.gd")
const ResolveAccess = preload("res://addons/_lib/dep_map/src/scanner/resolve_access.gd")

static var _preload_regex:RegEx
static var _load_regex:RegEx
static var _token_regex:RegEx
static var _string_regex:RegEx
static var _class_name_regex:RegEx
static var _inner_class_regex:RegEx
static var _access_regex:RegEx
static var _preload_const_regex:RegEx
static var _reduction_regexes:Dictionary = {}
static var _head_token_regexes:Dictionary = {}


static func _ensure_regex() -> void:
	if _preload_regex != null:
		return
	_preload_regex = URegex.get_preload_path()
	_string_regex = URegex.get_strings()
	_load_regex = RegEx.new()
	# \b keeps this off "preload(" - there is no word boundary inside it - while still
	# matching ResourceLoader.load("...").
	_load_regex.compile('\\bload\\((["\'])(.+?)\\1')
	_token_regex = RegEx.new()
	_token_regex.compile("\\b[a-zA-Z_]\\w*\\b")
	_class_name_regex = RegEx.new()
	_class_name_regex.compile("^\\s*class_name\\s+([a-zA-Z_]\\w*)")
	_inner_class_regex = RegEx.new()
	_inner_class_regex.compile("^\\s*class\\s+([a-zA-Z_]\\w*)")
	# Head.Segment(.Segment)* - the trailing (?!\() keeps `Foo.bar()` calls out of it
	_access_regex = RegEx.new()
	_access_regex.compile("\\b([A-Z][A-Za-z0-9_]*)((?:\\.[A-Za-z_]\\w*)+)\\b(?!\\s*\\()")
	# `preload(TAB_PATH)`: a constant expression, so the file is as required as a literal path
	_preload_const_regex = RegEx.new()
	_preload_const_regex.compile("\\bpreload\\(\\s*([A-Za-z_]\\w*)\\s*\\)")


## Returns an Array of ref dicts:
##   {"raw", "path"(optional, already absolute), "kind", "line_no", "tag", "meta"}
static func scan(file_path:String, ctx) -> Array:
	_ensure_regex()
	var text = FileAccess.get_file_as_string(file_path)
	if text == "":
		return []

	var map = StringMap.new(text)
	var line_starts = build_line_starts(text)
	var declared = _declared_names(text, map, line_starts)
	if not ctx.ignore_line_tags.is_empty():
		text = mask_ignored_lines(text, ctx.ignore_line_tags)
		map = StringMap.new(text)

	# Lines first: `extends Foo` is already a global-class use, so the token pass must not
	# emit a second edge for it.
	var line_refs:Array = []
	_scan_lines(text, map, line_starts, file_path, ctx, line_refs)
	var claimed = {}
	for ref:Dictionary in line_refs:
		if ref.kind == DepEdge.Kind.EXTENDS_CLASS:
			claimed[ref.raw] = true

	var refs:Array = []
	_scan_global_classes(text, map, line_starts, file_path, declared, claimed, ctx, refs)
	refs.append_array(line_refs)

	if ctx.resolve_access_paths:
		_scan_access_paths(text, map, line_starts, file_path, declared, ctx, refs)
	return refs


## Zero-based line numbers. Inspect real comments, including multiline-string context.
static func ignored_line_numbers(text:String, tags:Array) -> Dictionary:
	var ignored = {}
	if tags.is_empty() or not text.contains("#!"):
		return ignored
	var map = StringMap.new(text)
	var offset = 0
	var lines = text.split("\n")
	for i in lines.size():
		var line:String = lines[i]
		var start = _comment_start(line, map, offset)
		offset += line.length() + 1
		if start == -1:
			continue
		var comment = line.substr(start)
		for tag:String in tags:
			var marker = "#! " + tag
			if not comment.begins_with(marker):
				continue
			var rest = comment.substr(marker.length())
			if rest == "" or rest[0] in [" ", "\t", "\r", ";"]:
				ignored[i] = true
				break
	return ignored


## Preserve offsets so callers can compare filtered references against the original source.
static func mask_ignored_lines(text:String, tags:Array) -> String:
	var ignored = ignored_line_numbers(text, tags)
	if ignored.is_empty():
		return text
	var lines = text.split("\n")
	for i in ignored:
		lines[i] = " ".repeat(lines[i].length())
	return "\n".join(lines)


# `Singletons.Base` names singleton_base.gd, not the namespace file its head resolves to.
# These are emitted ALONGSIDE the head's own edge, never instead of it: the head has to exist for
# the source to compile, so whether a caller can do without it is marked, not assumed.
static func _scan_access_paths(text:String, map, line_starts:PackedInt32Array, file_path:String, declared:Dictionary, ctx, refs:Array) -> void:
	var heads = ResolveAccess.get_const_paths(file_path, ctx.access_cache)
	var class_map:Dictionary = ctx.class_map

	var lines = text.split("\n")
	var seen = {}
	var by_head = {}
	for m in _access_regex.search_all(text):
		var expression = m.get_string()
		if seen.has(expression):
			continue
		var head = m.get_string(1)
		if declared.has(head):
			continue
		var start = m.get_start()
		if _masked(map, start):
			continue
		seen[expression] = true

		var result = ResolveAccess.resolve(expression, heads, class_map, ctx.access_cache, file_path)
		var path:String = result.path
		if path == "":
			continue
		# a partial walk stopped at the head's own file - that edge already exists
		if result.partial and path == result.head_path:
			continue
		# a tagged value is more than its value: inlining it would skip the file holding the tag
		if result.literal != "" and _crosses_any_tag(result.crossed, file_path, ctx):
			continue

		var line_no = line_of(line_starts, start)
		# `extends Singletons.Base` is an inheritance edge to singleton_base.gd; only the
		# unresolved head reads as a plain class reference
		var kind = DepEdge.Kind.GLOBAL_CLASS
		if line_no - 1 < lines.size() and _is_extends_line(_code_part(lines[line_no - 1], map, line_starts[line_no - 1])):
			kind = DepEdge.Kind.EXTENDS_CLASS

		var reducible = _is_reducible(result, ctx)
		refs.append({
			"raw": expression,
			"path": file_path if result.literal != "" else path,
			"kind": kind,
			"line_no": line_no,
			"meta": {
				DepEdge.META_LITERAL: result.literal,
				DepEdge.META_RESOLVED_FROM: expression,
				DepEdge.META_PARTIAL: result.partial,
				DepEdge.META_CONSUMED: result.consumed,
				DepEdge.META_HEAD_FROM_CLASS_MAP: result.head_from_class_map,
				DepEdge.META_HEAD_PATH: result.head_path,
				DepEdge.META_SUFFIX: result.suffix,
				DepEdge.META_BIND_NAME: result.bind_name,
				DepEdge.META_CROSSED: result.crossed,
				DepEdge.META_REDUCIBLE: reducible,
			},
		})

		if reducible:
			if not by_head.has(head):
				by_head[head] = {"expressions": [], "blocked": false}
			by_head[head].expressions.append(expression)
			if _crosses_tag(result.crossed, file_path, path, ctx):
				by_head[head].blocked = true

	var passed = _mark_pass_through(text, map, line_starts, file_path, by_head, ctx, refs)
	_scan_preload_chains(file_path, heads, ctx, refs)
	_scan_inherited_consts(text, map, line_starts, file_path, passed, heads, ctx, refs)


# A local hub inside the kept dirs is staying regardless, so nothing is gained by rewriting around
# it. A global head reduces wherever it lives.
static func _is_reducible(result:Dictionary, ctx) -> bool:
	if result.consumed < 2:
		return false
	return result.head_from_class_map or not ctx.in_collapse_keep_dir(result.head_path)


static func _crosses_any_tag(crossed:Array, from_file:String, ctx) -> bool:
	for hop:Dictionary in crossed:
		if hop.file != from_file and not _tag_lines(hop.file, ctx).is_empty():
			return true
	return false


# A skipped file is never scanned, so a tag in it would silently stop firing. The file doing the
# walking and the one it lands on are both scanned, so only what lies between them counts.
static func _crosses_tag(crossed:Array, from_file:String, landing:String, ctx) -> bool:
	for hop:Dictionary in crossed:
		for path:String in [hop.file, hop.path]:
			if path != from_file and path != landing and not _tag_lines(path, ctx).is_empty():
				return true
	return false


static func _tag_lines(file_path:String, ctx) -> Dictionary:
	if ctx.tag_handlers.is_empty():
		return {}
	var key = "tags:" + file_path
	if not ctx.access_cache.has(key):
		ctx.access_cache[key] = ignored_line_numbers(FileAccess.get_file_as_string(file_path), ctx.tag_handlers.keys())
	return ctx.access_cache[key]


# Marks the head refs of everything this file only ever walks through. Loops because dropping one
# declaration can free the head on its right: `const H = Lib.Hub` is Lib's only mention.
static func _mark_pass_through(text:String, map, line_starts:PackedInt32Array, file_path:String, by_head:Dictionary, ctx, refs:Array) -> Dictionary:
	var entries = ResolveAccess.get_const_entries(file_path, ctx.access_cache)
	var tagged = _tag_lines(file_path, ctx)
	var passed = {}
	var gone = {} # line_no -> const name, for declarations that will not survive
	var changed = true
	while changed:
		changed = false
		for head:String in by_head:
			if passed.has(head) or by_head[head].blocked:
				continue
			var entry = entries.get(head)
			var own_line:int = 0 if entry == null or entry.indented else entry.line
			if tagged.has(own_line - 1):
				continue
			var skip = gone.duplicate()
			if own_line > 0:
				skip[own_line] = head
			if not head_fully_reduced(text, map, line_starts, head, by_head[head].expressions, skip):
				continue
			passed[head] = true
			if own_line > 0:
				gone[own_line] = head
			changed = true

	for ref:Dictionary in refs:
		var meta:Dictionary = ref.get("meta", {})
		# a class ref sits at its first mention, which says nothing about the rest of the file
		if meta.has("class"):
			if passed.has(ref.raw):
				meta[DepEdge.META_PASS_THROUGH] = true
		elif gone.has(ref.line_no) and ref.kind != DepEdge.Kind.TAG and _only_on_lines(text, map, line_starts, meta, gone):
			meta[DepEdge.META_PASS_THROUGH] = true
			meta[DepEdge.META_CONST_NAME] = gone[ref.line_no]
		ref["meta"] = meta
	return passed


# An expression is recorded once, at its first occurrence, so that line alone proves nothing.
static func _only_on_lines(text:String, map, line_starts:PackedInt32Array, meta:Dictionary, lines:Dictionary) -> bool:
	var expression:String = meta.get(DepEdge.META_RESOLVED_FROM, "")
	if expression == "":
		return true
	for m in get_reduction_regex(expression).search_all(text):
		if not _masked(map, m.get_start()) and not lines.has(line_of(line_starts, m.get_start())):
			return false
	return true


## True when every mention of `head` in `text` is the head of one of `expressions`, so the file
## needs neither it nor whatever it preloads. `skip_lines` are 1-based lines not to count, which
## is how a local head ignores its own declaration.
static func head_fully_reduced(text:String, map, line_starts:PackedInt32Array, head:String, expressions:Array, skip_lines:Dictionary = {}) -> bool:
	var reduced_at = {}
	for expression:String in expressions:
		for m in get_reduction_regex(expression).search_all(text):
			reduced_at[m.get_start()] = true

	for m in _head_token_regex(head).search_all(text):
		var index = m.get_start()
		if _masked(map, index) or is_member_access(text, index):
			continue # a tail segment elsewhere, not a use of this head
		if not reduced_at.has(index) and not skip_lines.has(line_of(line_starts, index)):
			return false
	return true


## What each dotted access path reduces to: {expression: {name, parent, path, tail}}. An
## expression whose head is already the deepest file it names is a genuine use, and a local head
## inside collapse_keep_dirs is left alone, so neither carries META_REDUCIBLE.
static func plan_reductions(edges:Array, out:Dictionary) -> Dictionary:
	for edge in edges:
		var expression:String = edge.meta.get(DepEdge.META_RESOLVED_FROM, "")
		if expression == "" or edge.to == "" or out.has(expression):
			continue
		if not edge.meta.get(DepEdge.META_REDUCIBLE, false):
			continue
		var consumed:int = edge.meta.get(DepEdge.META_CONSUMED, 0)
		var parts = expression.split(".", false)
		var literal:String = edge.meta.get(DepEdge.META_LITERAL, "")
		if literal != "":
			out[expression] = {"name": literal, "parent": "", "path": "", "tail": [], "literal": true}
			continue
		out[expression] = {
			"name": edge.meta.get(DepEdge.META_BIND_NAME, parts[consumed - 1]),
			# the segment above it, the first fallback when two reductions want the same name
			"parent": parts[consumed - 2],
			"path": edge.to,
			"tail": edge.meta.get(DepEdge.META_SUFFIX, []) + Array(parts.slice(consumed)),
		}
	return out


## Matches an expression as a whole dotted token. The lookbehind keeps it off a longer chain
## that merely ends with it ("Other.ALibRuntime.Utils"), and the trailing boundary keeps
## "A.B.UFile" from matching inside "A.B.UFileWatcher".
static func get_reduction_regex(expression:String) -> RegEx:
	var regex = _reduction_regexes.get(expression)
	if regex == null:
		regex = RegEx.new()
		regex.compile("(?<![.\\w])%s\\b" % expression.replace(".", "\\."))
		_reduction_regexes[expression] = regex
	return regex


static func _head_token_regex(head:String) -> RegEx:
	var regex = _head_token_regexes.get(head)
	if regex == null:
		regex = RegEx.new()
		regex.compile("\\b%s\\b" % head)
		_head_token_regexes[head] = regex
	return regex


static func is_member_access(text:String, index:int) -> bool:
	return index >= 1 and text[index - 1] == "."


# `const O = preload("a.gd").Hub` never reaches the access pass, because the expression has no head
# to match. Reported so whatever it crosses in a.gd is kept.
static func _scan_preload_chains(file_path:String, heads:Dictionary, ctx, refs:Array) -> void:
	var entries = ResolveAccess.get_const_entries(file_path, ctx.access_cache)
	for name:String in entries:
		var entry:Dictionary = entries[name]
		if entry.indented or entry.get("rest", []).is_empty():
			continue
		var result = ResolveAccess.resolve(name, heads, ctx.class_map, ctx.access_cache, file_path)
		if result.path == "" or result.path == entry.path:
			continue
		refs.append(_unreduced_ref(name, result, entry.line))


# An inherited const this file still uses has to survive in the base, and the base cannot see that
# from where it stands. Bare mentions count: the dotted pass only ever sees chains.
static func _scan_inherited_consts(text:String, map, line_starts:PackedInt32Array, file_path:String, passed:Dictionary, heads:Dictionary, ctx, refs:Array) -> void:
	for name:String in ResolveAccess.get_inherited_consts(file_path, ctx.class_map, ctx.access_cache):
		if passed.has(name):
			continue
		for m in _head_token_regex(name).search_all(text):
			var index = m.get_start()
			if _masked(map, index) or is_member_access(text, index):
				continue
			var result = ResolveAccess.resolve(name, heads, ctx.class_map, ctx.access_cache, file_path)
			if result.path != "" and result.path != file_path:
				refs.append(_unreduced_ref(name, result, line_of(line_starts, index)))
			break


static func _unreduced_ref(raw:String, result:Dictionary, line_no:int) -> Dictionary:
	return {
		"raw": raw,
		"path": result.path,
		"kind": DepEdge.Kind.GLOBAL_CLASS,
		"line_no": line_no,
		"meta": {
			DepEdge.META_RESOLVED_FROM: raw,
			DepEdge.META_CONSUMED: result.consumed,
			DepEdge.META_CROSSED: result.crossed,
			DepEdge.META_REDUCIBLE: false,
		},
	}


static func _is_extends_line(code:String) -> bool:
	var stripped = code.strip_edges()
	return stripped.begins_with("extends ") or (stripped.begins_with("class_name ") and stripped.contains(" extends "))


# Global class names recur constantly by nature, so only the first use of each is recorded -
# unlike explicit references, where every occurrence is kept.
static func _scan_global_classes(text:String, map, line_starts:PackedInt32Array, file_path:String, declared:Dictionary, seen:Dictionary, ctx, refs:Array) -> void:
	var class_map:Dictionary = ctx.class_map
	if class_map.is_empty():
		return
	for m in _token_regex.search_all(text):
		var word = m.get_string()
		if seen.has(word) or declared.has(word) or not class_map.has(word):
			continue
		var start = m.get_start()
		if _masked(map, start):
			continue
		seen[word] = true
		var path:String = class_map[word]
		if path == file_path:
			continue
		refs.append({
			"raw": word,
			"path": path,
			"kind": DepEdge.Kind.GLOBAL_CLASS,
			"line_no": line_of(line_starts, start),
			"meta": {"class": word},
		})


static func _scan_lines(text:String, map, line_starts:PackedInt32Array, file_path:String, ctx, refs:Array) -> void:
	var lines = text.split("\n")
	var tag_handlers:Dictionary = ctx.tag_handlers
	for i in lines.size():
		var line:String = lines[i]
		if line == "":
			continue
		var offset = line_starts[i]
		var line_no = i + 1

		for m in _preload_regex.search_all(line):
			if _masked(map, offset + m.get_start()):
				continue
			refs.append(_ref(m.get_string(2), DepEdge.Kind.PRELOAD, line_no))

		for m in _preload_const_regex.search_all(line):
			if _masked(map, offset + m.get_start()):
				continue
			var named = ResolveAccess.get_const_entries(file_path, ctx.access_cache).get(m.get_string(1), {}).get("literal", "")
			if named.length() > 2:
				refs.append(_ref(named.substr(1, named.length() - 2), DepEdge.Kind.PRELOAD, line_no))

		for m in _load_regex.search_all(line):
			if _masked(map, offset + m.get_start()):
				continue
			refs.append(_ref(m.get_string(2), DepEdge.Kind.LOAD, line_no))

		var comment_start = _comment_start(line, map, offset)
		_scan_extends(line if comment_start == -1 else line.substr(0, comment_start), line_no, ctx, refs)

		if not tag_handlers.is_empty() and comment_start != -1:
			_scan_tags(line, comment_start, file_path, line_no, tag_handlers, refs)


static func _scan_extends(code:String, line_no:int, ctx, refs:Array) -> void:
	var stripped = code.strip_edges()
	if not stripped.contains("extends"):
		return
	var rest := ""
	if stripped.begins_with("extends "):
		rest = stripped.substr(8).strip_edges()
	elif stripped.begins_with("class_name ") and stripped.contains(" extends "):
		rest = stripped.get_slice(" extends ", 1).strip_edges()
	else:
		return
	if rest == "":
		return

	if rest.begins_with('"') or rest.begins_with("'"):
		var quote = rest[0]
		var end = rest.find(quote, 1)
		if end > -1:
			refs.append(_ref(rest.substr(1, end - 1), DepEdge.Kind.EXTENDS_PATH, line_no))
		return

	# `extends Foo.Bar` - only the head can be a global class.
	var head = rest.get_slice(".", 0).get_slice(" ", 0).strip_edges()
	var path = ctx.class_map.get(head)
	if path != null:
		refs.append({
			"raw": head,
			"path": path,
			"kind": DepEdge.Kind.EXTENDS_CLASS,
			"line_no": line_no,
			"meta": {"class": head},
		})


# The tag has to OPEN the comment, matching how every other "#!" directive in this project is
# written. Without that, prose mentioning a tag - this file's own docs, for one - fires it.
static func _scan_tags(line:String, comment_start:int, file_path:String, line_no:int, tag_handlers:Dictionary, refs:Array) -> void:
	var comment = line.substr(comment_start)
	for tag:String in tag_handlers:
		var marker = "#! " + tag
		if not comment.begins_with(marker):
			continue
		var value = comment.substr(marker.length()).strip_edges()
		var raws = _line_string_literals(line)
		var handler:Callable = tag_handlers[tag]
		var result = handler.call({
			"file_path": file_path,
			"line": line,
			"line_no": line_no,
			"tag": tag,
			"value": value,
			"raws": raws,
		})
		if result == null:
			continue
		var meta:Dictionary = result if result is Dictionary else {}
		var targets:Array = meta.get("paths", raws)
		meta.erase("paths")
		for raw:String in targets:
			var ref = _ref(raw, DepEdge.Kind.TAG, line_no)
			ref["tag"] = tag
			ref["meta"] = meta.duplicate()
			refs.append(ref)


static func _line_string_literals(line:String) -> Array:
	var out:Array = []
	for m in _string_regex.search_all(line):
		var raw = m.get_string()
		raw = raw.substr(1, raw.length() - 2)
		if Resolve.looks_like_path(raw):
			out.append(raw)
	return out


static func _declared_names(text:String, map, line_starts:PackedInt32Array) -> Dictionary:
	var declared = {}
	var lines = text.split("\n")
	for i in lines.size():
		var code = _code_part(lines[i], map, line_starts[i])
		var m = _class_name_regex.search(code)
		if m == null:
			m = _inner_class_regex.search(code)
		if m != null:
			declared[m.get_string(1)] = true
	return declared


## The line with its trailing comment removed, using the mask rather than a naive "#" search.
static func _code_part(line:String, map, offset:int) -> String:
	var start = _comment_start(line, map, offset)
	return line if start == -1 else line.substr(0, start)


## Index of the "#" opening this line's comment, or -1. Mask-based, so a "#" inside a string
## literal is not mistaken for one.
static func _comment_start(line:String, map, offset:int) -> int:
	var size = map.comment_mask.size()
	for i in line.length():
		var idx = offset + i
		if idx >= size:
			break
		if map.comment_mask[idx] == 1:
			return i
	return -1


static func _masked(map, index:int) -> bool:
	if index < 0 or index >= map.comment_mask.size():
		return false
	return map.index_in_string_or_comment(index)


static func _ref(raw:String, kind:int, line_no:int) -> Dictionary:
	return {"raw": raw, "kind": kind, "line_no": line_no}


static func build_line_starts(text:String) -> PackedInt32Array:
	var starts = PackedInt32Array([0])
	var idx = text.find("\n")
	while idx != -1:
		starts.append(idx + 1)
		idx = text.find("\n", idx + 1)
	return starts


static func line_of(line_starts:PackedInt32Array, index:int) -> int:
	var lo = 0
	var hi = line_starts.size() - 1
	while lo < hi:
		var mid = (lo + hi + 1) >> 1
		if line_starts[mid] <= index:
			lo = mid
		else:
			hi = mid - 1
	return lo + 1
