## Result of a dependency scan: every file reached, and every reference that reached it.
## Built by dependencies.gd - callers only read it.

## Paths the scan was seeded with.
var roots:PackedStringArray = PackedStringArray()
## {path: DepNode}, insertion-ordered by first discovery.
var nodes:Dictionary = {}
## Every DepEdge, in discovery order.
var edges:Array = []
## Edges whose target could not be resolved to a path (dead uid, bad relative path).
var unresolved:Array = []
## {ClassName: {"path": String, "first_seen": String}} for every global class referenced.
var global_classes:Dictionary = {}


func has(path:String) -> bool:
	return nodes.has(path)


func get_node_data(path:String):
	return nodes.get(path)


## Files that reference `path`.
func get_dependents(path:String) -> PackedStringArray:
	var node = nodes.get(path)
	if node == null:
		return PackedStringArray()
	return node.get_dependent_paths()


## Files that `path` references.
func get_dependencies(path:String) -> PackedStringArray:
	var node = nodes.get(path)
	if node == null:
		return PackedStringArray()
	return node.get_dependency_paths()


## The DepEdges pointing at `path` - kind, line and raw text of each reference.
func get_in_edges(path:String) -> Array:
	var node = nodes.get(path)
	return node.in_edges if node != null else []


func get_out_edges(path:String) -> Array:
	var node = nodes.get(path)
	return node.out_edges if node != null else []


func get_paths(include_missing:bool=false, include_roots:bool=true) -> PackedStringArray:
	var out = PackedStringArray()
	for path:String in nodes:
		var node = nodes[path]
		if not include_missing and not node.exists:
			continue
		if not include_roots and node.is_root:
			continue
		out.append(path)
	return out


## Reached paths that are not on disk - dangling references worth reporting.
func get_missing() -> PackedStringArray:
	var out = PackedStringArray()
	for path:String in nodes:
		if not nodes[path].exists:
			out.append(path)
	return out


func get_edges_of_kind(kind:int) -> Array:
	var out = []
	for edge in edges:
		if edge.kind == kind:
			out.append(edge)
	return out


## {path: DepEdge} - for every non-root node, the single edge on its shortest path from a
## root. This is the graph's spanning tree: one parent each, no cycles, which is what makes
## "why is this file here" answerable without reading 400 crossing lines.
##
## `allow` is an optional Callable(DepEdge) -> bool. A caller that draws only some of the edges
## passes its own filter here, so the parent it gets back is one it will actually draw - the
## alternative is a node left with no incoming line at all.
func get_tree_parents(allow:Callable = Callable()) -> Dictionary:
	var parents = {}
	for path:String in nodes:
		var node = nodes[path]
		if node.is_root:
			continue
		var best_edge = null
		for edge in node.in_edges:
			if allow.is_valid() and not allow.call(edge):
				continue
			if _better_parent(edge, best_edge):
				best_edge = edge
		if best_edge != null:
			parents[path] = best_edge
	return parents


## {path: true} for every node reachable from a root through edges `allow` accepts. Roots are
## always included. Filtering edges without this leaves behind nodes nothing points at any
## more, which read as unexplained floating files.
func get_reachable(allow:Callable = Callable()) -> Dictionary:
	var seen = {}
	var queue:Array = []
	for root:String in roots:
		if nodes.has(root) and not seen.has(root):
			seen[root] = true
			queue.append(root)

	while not queue.is_empty():
		var node = nodes[queue.pop_front()]
		for edge in node.out_edges:
			if edge.to == "" or seen.has(edge.to) or not nodes.has(edge.to):
				continue
			if allow.is_valid() and not allow.call(edge):
				continue
			seen[edge.to] = true
			queue.append(edge.to)
	return seen


# Shallowest source wins. A namespace-hub detour loses to any real reference at the same
# depth, and the source path breaks remaining ties so the tree is stable across runs.
func _better_parent(edge, best) -> bool:
	if best == null:
		return true
	var parent = nodes.get(edge.from)
	var best_parent = nodes.get(best.from)
	if parent == null:
		return false
	if best_parent == null:
		return true
	if parent.depth != best_parent.depth:
		return parent.depth < best_parent.depth
	var via_hub:bool = edge.meta.get("namespace_hub", false)
	var best_via_hub:bool = best.meta.get("namespace_hub", false)
	if via_hub != best_via_hub:
		return not via_hub
	return edge.from < best.from


## Shortest reference chain from a root to `path`, roots-first. Empty if unreachable.
func get_path_to(path:String) -> PackedStringArray:
	var parents = get_tree_parents()
	var chain = PackedStringArray()
	var current:String = path
	var guard = {}
	while current != "" and not guard.has(current):
		guard[current] = true
		chain.append(current)
		var edge = parents.get(current)
		if edge == null:
			break
		current = edge.from
	chain.reverse()
	return chain


func to_dict() -> Dictionary:
	var node_dicts = {}
	for path:String in nodes:
		node_dicts[path] = nodes[path].to_dict()
	var edge_dicts = []
	for edge in edges:
		edge_dicts.append(edge.to_dict())
	var unresolved_dicts = []
	for edge in unresolved:
		unresolved_dicts.append(edge.to_dict())
	return {
		"roots": roots,
		"nodes": node_dicts,
		"edges": edge_dicts,
		"unresolved": unresolved_dicts,
		"global_classes": global_classes,
	}


func format_tree() -> String:
	var lines:Array[String] = []
	var seen = {}
	for root in roots:
		_format_branch(root, "", lines, seen)
	return "\n".join(lines)


func _format_branch(path:String, indent:String, lines:Array[String], seen:Dictionary) -> void:
	var node = nodes.get(path)
	var suffix := ""
	if node == null or not node.exists:
		suffix = "  [missing]"
	elif seen.has(path):
		lines.append("%s%s  [seen]" % [indent, path])
		return
	seen[path] = true
	lines.append("%s%s%s" % [indent, path, suffix])
	if node == null:
		return
	for child in node.get_dependency_paths():
		_format_branch(child, indent + "    ", lines, seen)


func _to_string() -> String:
	return "DepGraph(%d nodes, %d edges, %d unresolved)" % [nodes.size(), edges.size(), unresolved.size()]
