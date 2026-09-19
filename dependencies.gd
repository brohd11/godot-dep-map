## Recursive resource-dependency collector. Text-only: nothing is loaded, nothing is
## imported, so it runs headless and on files the editor has never seen.
##
## Configure an instance and call get_graph(), or use the static one-shot. Unlike a flat
## {dependency: dependent} map, the returned DepGraph keeps every reference - so a file
## preloaded from three places still knows all three, with the kind, line and original
## text of each.
##
##     const UDep = UResource.Dependencies
##
##     var graph = UDep.scan("res://addons/foo/plugin.gd")
##     print(graph.get_dependents("res://addons/foo/src/thing.gd"))
##
##     var d = UDep.open("res://addons/foo/plugin.gd")
##     d.ignore_dir_paths = ["res://addons/foo/export_ignore"]
##     d.add_tag_handler("asset", func(ctx): return {"dir": ctx.value})
##     var graph = d.get_graph()
##
## open()/scan()/get_graph() mirror UFile.GetFiles, which pairs a static one-shot with an
## instance getter for the same reason: the two cannot share a name.

const SELF = preload("res://addons/addon_lib/dep_map/dependencies.gd")

const DepGraph = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/dep_graph.gd")
const DepNode = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/dep_node.gd")
const DepEdge = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/dep_edge.gd")
const Resolve = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/resolve.gd")
const ResolveAccess = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/resolve_access.gd")
const ScanGD = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/scan_gd.gd")
const ScanSer = preload("res://addons/addon_lib/brohd/alib_runtime/utils/resource/dependencies/scan_ser.gd")

const Kind = DepEdge.Kind

const SCANNERS = {
	"gd": ScanGD,
	"tscn": ScanSer,
	"tres": ScanSer,
	"scn": ScanSer,
	"res": ScanSer,
}

const DEFAULT_EXTENSIONS = ["gd", "tscn", "tres"]

## Files the scan starts from. Set by open()/open_many(), reassignable to reuse an instance.
var roots:Array = []
## Extensions to recurse into. Anything else is still recorded, as a leaf.
var follow_extensions:Array = DEFAULT_EXTENSIONS.duplicate()
## Hops from a root to stop at. -1 exhausts the graph.
var max_depth:int = -1
## Absolute directory paths to drop entirely - no node, no edge.
var ignore_dir_paths:Array = []
## Bare directory names to drop at any depth, e.g. "export_ignore".
var ignore_dir_names:Array = []
## Absolute file paths to drop entirely.
var ignore_paths:Array = []
## Directories to record but not descend into - the edge survives, the recursion stops.
var stop_at_dir_paths:Array = []
## Recurse through load() as well as preload(). A runtime load() is often an optional
## integration pointing outside the tree of interest, so set false to record the edge and
## stop there.
var follow_load:bool = true
## Record references to files that are not on disk as exists=false nodes.
var include_missing:bool = true
## {ClassName: path}. Left empty, the project's global class list fills it on the first scan
## and stays on the instance - call clear_class_map() to pick up a newly added class_name.
var class_map:Dictionary = {}
## Set false with an empty class_map to skip global-class resolution entirely.
var use_project_classes:bool = true
## Walk dotted access paths - `Singletons.Base` names singleton_base.gd, not the namespace
## file its head resolves to. Purely additive: the head's own GLOBAL_CLASS edge is emitted
## either way, so turning this off can never lose a dependency, only precision.
var resolve_access_paths:bool = true
## {tag_name_without_prefix: Callable}. Empty means every "#!" tag is an ordinary comment.
var tag_handlers:Dictionary = {}
## Tags that suppress references on their line. Empty keeps the collector policy-neutral.
var ignore_line_tags:Array = []

## {file_path: {const_name: target}} plus "autogen:<path>" flags, shared for one scan.
var access_cache:Dictionary = {}

var _ignore_dirs:Array = []
var _ignore_names:Dictionary = {}
var _ignore_files:Dictionary = {}
var _stop_dirs:Array = []
var _follow:Dictionary = {}

static var _project_class_map:Dictionary = {}
static var _project_class_map_built:bool = false


static func open(root:String) -> SELF:
	var ins = new()
	ins.roots = [root]
	return ins


static func open_many(_roots:Array) -> SELF:
	var ins = new()
	ins.roots = _roots.duplicate()
	return ins


## One call, no configuration.
static func scan(root:String) -> DepGraph:
	return open(root).get_graph()


static func scan_many(_roots:Array) -> DepGraph:
	return open_many(_roots).get_graph()


## Registers a handler for the `#! <tag>` directive. Nothing here is built in - a tag with no
## handler is an ordinary comment - so the tags a project uses stay with the project.
##
## `handler` is a Callable taking one context dict:
##     {"file_path", "line", "line_no", "tag", "value", "raws"}
## `value` is the text after the tag, `raws` the path-looking string literals on the line.
## Return a Dictionary to emit one TAG edge per entry in `raws` carrying it as edge.meta, or
## null to emit nothing. A returned "paths" key replaces `raws` as the edge targets and is
## stripped from the metadata.
##
##     d.add_tag_handler("asset", func(ctx):
##         return null if ctx.raws.is_empty() else {"dir": ctx.value})
##
## Chainable so a scan can be configured in one expression.
func add_tag_handler(tag:String, handler:Callable) -> SELF:
	tag_handlers[tag.trim_prefix("#!").strip_edges()] = handler
	return self


func clear_class_map() -> void:
	class_map = {}


func get_graph() -> DepGraph:
	var graph = DepGraph.new()
	_build_lookups()
	access_cache.clear()
	if class_map.is_empty() and use_project_classes:
		class_map = get_project_class_map()

	var queue:Array = []
	for root:String in roots:
		var path = Resolve.to_path(root, "")
		if path == "" or _ignored(path):
			continue
		if graph.nodes.has(path):
			continue
		var node = _ensure_node(graph, path, 0)
		node.is_root = true
		graph.roots.append(path)
		queue.append(path)

	var scanned:Dictionary = {}
	while not queue.is_empty():
		var path:String = queue.pop_front()
		if scanned.has(path):
			continue
		scanned[path] = true

		var node = graph.nodes[path]
		if not _can_scan(node):
			continue
		node.scanned = true

		for ref:Dictionary in SCANNERS[node.extension].scan(path, self):
			var child = _add_ref(graph, node, ref)
			if child == null or scanned.has(child.path):
				continue
			if not follow_load and ref.kind == Kind.LOAD:
				continue
			queue.append(child.path)

	return graph


# Returns the child node when one was created or reached, null when the reference was
# unresolved, ignored, or a self-reference.
func _add_ref(graph:DepGraph, node:DepNode, ref:Dictionary):
	var target:String = ref.get("path", "")
	if target == "":
		target = Resolve.to_path(ref.raw, node.path)

	var edge = DepEdge.new(node.path, target, ref.kind, ref.get("line_no", 0), ref.raw, ref.get("tag", ""))
	edge.meta = ref.get("meta", {})

	if target == "":
		graph.edges.append(edge)
		graph.unresolved.append(edge)
		node.out_edges.append(edge)
		return null
	if target == node.path or _ignored(target):
		return null

	var exists = FileAccess.file_exists(target)
	if not exists and not include_missing:
		return null

	var child = _ensure_node(graph, target, node.depth + 1)
	if child.is_namespace_hub:
		edge.meta["namespace_hub"] = true

	graph.edges.append(edge)
	node.out_edges.append(edge)
	child.in_edges.append(edge)

	var cls = edge.meta.get("class", "")
	if cls != "" and not graph.global_classes.has(cls):
		graph.global_classes[cls] = {"path": target, "first_seen": node.path}

	return child


# The hub flag is decided here, once per file, rather than in the scanners: a preload's target
# is a raw uid or relative path until it has been resolved, so nothing upstream knows what file
# it lands on.
func _ensure_node(graph:DepGraph, path:String, depth:int) -> DepNode:
	var node = graph.nodes.get(path)
	if node == null:
		node = DepNode.new(path, depth)
		node.is_namespace_hub = node.exists and ResolveAccess.is_generated_namespace_file(path, access_cache)
		graph.nodes[path] = node
	elif depth < node.depth:
		node.depth = depth
	return node


func _can_scan(node:DepNode) -> bool:
	if not node.exists:
		return false
	if not _follow.has(node.extension) or not SCANNERS.has(node.extension):
		return false
	if max_depth >= 0 and node.depth >= max_depth:
		return false
	for dir:String in _stop_dirs:
		if node.path.begins_with(dir):
			return false
	return true


func _ignored(path:String) -> bool:
	if _ignore_files.has(path):
		return true
	for dir:String in _ignore_dirs:
		if path.begins_with(dir):
			return true
	if not _ignore_names.is_empty():
		for part in path.get_base_dir().split("/"):
			if _ignore_names.has(part):
				return true
	return false


func _build_lookups() -> void:
	_follow.clear()
	for e:String in follow_extensions:
		_follow[e.to_lower()] = true

	_ignore_files.clear()
	for f:String in ignore_paths:
		_ignore_files[f] = true

	_ignore_names.clear()
	for n:String in ignore_dir_names:
		_ignore_names[n] = true

	_ignore_dirs = _with_slashes(ignore_dir_paths)
	_stop_dirs = _with_slashes(stop_at_dir_paths)


static func _with_slashes(dirs:Array) -> Array:
	var out:Array = []
	for d:String in dirs:
		out.append(d if d.ends_with("/") else d + "/")
	return out


## {ClassName: script_path} for every global class in the project. Built once.
static func get_project_class_map() -> Dictionary:
	if not _project_class_map_built:
		_project_class_map_built = true
		for entry in ProjectSettings.get_global_class_list():
			_project_class_map[entry.get("class", "")] = entry.get("path", "")
		_project_class_map.erase("")
	return _project_class_map


## Call after adding or renaming a class_name if the map was already built this session.
static func clear_project_class_map() -> void:
	_project_class_map.clear()
	_project_class_map_built = false
