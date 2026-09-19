## One file in the graph. `in_edges` answers "what pulls this in?", `out_edges` answers
## "what does this need?" - both hold DepEdge instances, so the reference kind and line
## survive alongside the connection.

const UFile = preload("uid://bl33psa06nv1e") #! resolve ALibRuntime.Utils.UFile.Methods

var path:String
## Resolved lazily - ResourceLoader lookups are not free and most callers never ask.
var _uid:String = ""
var _uid_read:bool = false
var exists:bool = false
var extension:String = ""
## Fewest hops from any root. Roots are 0.
var depth:int = 0
var is_root:bool = false
## False when the extension has no scanner, or when traversal stopped here.
var scanned:bool = false
## A generated pseudo-namespace file. It preloads every sibling it namespaces, so a viewer may
## want to elide it - but it is a real file a caller collecting files still has to keep.
var is_namespace_hub:bool = false

var in_edges:Array = []
var out_edges:Array = []


func _init(_path:String="", _depth:int=0) -> void:
	path = _path
	depth = _depth
	extension = _path.get_extension().to_lower()
	exists = _path != "" and FileAccess.file_exists(_path)


func get_dir() -> String:
	return path.get_base_dir()


func get_uid() -> String:
	if not _uid_read:
		_uid_read = true
		if exists:
			var uid = UFile.path_to_uid(path)
			_uid = uid if uid != path else ""
	return _uid


## Unique dependents, in first-seen order.
func get_dependent_paths() -> PackedStringArray:
	return _unique_paths(in_edges, true)


## Unique dependencies, in first-seen order.
func get_dependency_paths() -> PackedStringArray:
	return _unique_paths(out_edges, false)


func _unique_paths(edges:Array, use_from:bool) -> PackedStringArray:
	var seen = {}
	var out = PackedStringArray()
	for edge in edges:
		var p:String = edge.from if use_from else edge.to
		if p == "" or seen.has(p):
			continue
		seen[p] = true
		out.append(p)
	return out


func to_dict() -> Dictionary:
	return {
		"path": path,
		"uid": get_uid(),
		"exists": exists,
		"extension": extension,
		"depth": depth,
		"is_root": is_root,
		"scanned": scanned,
		"is_namespace_hub": is_namespace_hub,
		"dependents": get_dependent_paths(),
		"dependencies": get_dependency_paths(),
	}


func _to_string() -> String:
	return "DepNode(%s, depth=%d, in=%d, out=%d)" % [path, depth, in_edges.size(), out_edges.size()]
