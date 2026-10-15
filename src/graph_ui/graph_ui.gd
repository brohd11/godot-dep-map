@tool
#! namespace DepMap class GraphUI
extends GraphEdit
## Visualizes a DepGraph from DepMap.Scanner as a node graph - one node per file,
## connections coloured by reference kind.
##
## It takes files and nothing else; whatever UI chooses those files lives outside this class.
##
##     var panel = DepMap.GraphUI.new()
##     panel.set_files(["res://addons/foo/plugin.gd", "res://addons/foo/thing.tscn"])
##
##     # or render a graph the caller already scanned
##     panel.set_graph(DepMap.Scanner.scan(path))
##
##     # or centre on one file: only its neighbourhood is drawn, out to focus_depth hops
##     panel.set_focus("res://addons/foo/plugin.gd", 2)
##
## This is a viewer: connections cannot be made or broken, so connection_request and
## disconnect_node_request are deliberately left unwired.

const Scanner = preload("res://addons/_lib/dep_map/src/scanner.gd")
const DepFileNode = preload("res://addons/_lib/dep_map/src/graph_ui/dep_file_node.gd")
const KindStyle = preload("res://addons/_lib/dep_map/src/graph_ui/kind_style.gd")
const Layout = preload("res://addons/_lib/dep_map/src/graph_ui/layout.gd")

const Kind = Scanner.Kind

## Which connections get drawn. Orthogonal to the layout - either mode works with either.
enum EdgeMode {
	ALL,   ## every reference
	TREE,  ## one parent per file: the edge on its shortest path from a root
}

## Where the nodes go. Orthogonal to EdgeMode.
enum LayoutMode {
	DEPTH,  ## columns are hops from a root - reads as "what depends on what"
	FOLDER, ## grouped into a GraphFrame per directory - navigable at filesystem scale
}

const VIEW_MARGIN = 40.0
const LINE_THICKNESS = 2.5

## Emitted on selection change; path is "" when the selection is cleared.
signal file_selected(path:String)
signal file_activated(path:String)
## The DepEdges behind a clicked connection - GraphEdit collapses duplicates, this does not.
signal edge_activated(edges:Array)
signal graph_built(node_count:int, truncated:bool)

# --- scan config, used by set_files() ---
var scan_max_depth:int = -1
var scan_follow_load:bool = true
var scan_follow_extensions:Array = ["gd", "tscn", "tres"]
var scan_ignore_dir_paths:Array = []
var scan_ignore_dir_names:Array = []
var scan_tag_handlers:Dictionary = {}
var scan_ignore_line_tags:Array = []

## Unscaled gaps between nodes; both are multiplied by the editor scale at layout time.
## Vertical needs the most - columns are already separated by node width.
#var v_gap:float = 140.0:
var v_gap:float = 300:
	set(value):
		v_gap = value
		if _graph != null:
			_apply_layout()
#var h_gap:float = 330.0:
var h_gap:float = 600:
	set(value):
		h_gap = value
		if _graph != null:
			_apply_layout()

## FOLDER layout spacing, unscaled: between stacked files inside a frame, between columns of
## frames, between sibling frames, and the frame's own inner margin.
var folder_file_gap:float = 24.0:
	set(value):
		folder_file_gap = value
		if _graph != null and node_layout == LayoutMode.FOLDER:
			_apply_layout()
var folder_gap:float = 140.0:
	set(value):
		folder_gap = value
		if _graph != null and node_layout == LayoutMode.FOLDER:
			_apply_layout()
var folder_row_gap:float = 40.0:
	set(value):
		folder_row_gap = value
		if _graph != null and node_layout == LayoutMode.FOLDER:
			_apply_layout()
var folder_padding:float = 28.0:
	set(value):
		folder_padding = value
		if _graph != null and node_layout == LayoutMode.FOLDER:
			_apply_layout()

var edge_mode:EdgeMode = EdgeMode.ALL:
	set(value):
		if edge_mode == value:
			return
		edge_mode = value
		if _graph != null:
			_rebuild()

var node_layout:LayoutMode = LayoutMode.DEPTH:
	set(value):
		if node_layout == value:
			return
		node_layout = value
		if _graph != null:
			_rebuild()

## In TREE mode, also draw the edges the tree left out. They are drawn at full strength -
## GraphEdit has no per-connection alpha - so this is genuinely "show everything, tree first"
## rather than a subtle background layer.
var show_secondary_edges:bool = false:
	set(value):
		show_secondary_edges = value
		if _graph != null and edge_mode == EdgeMode.TREE:
			_rebuild()

## Drop generated pseudo-namespace files, node and edges both. Off by default: a hub that is
## referenced is a real file and belongs on screen. Turning it on is for the case where the
## hub's fan-out to every sibling it namespaces is more noise than the hub is worth - the
## files behind it stay reachable, because the collector resolves dotted access paths.
var hide_namespace_hubs:bool = false:
	set(value):
		hide_namespace_hubs = value
		if _graph != null:
			_rebuild()

## Dead uids and unresolvable paths get a red stub node instead of vanishing.
var show_unresolved:bool = true
## Referenced files that are not on disk are drawn dimmed rather than dropped.
var show_missing:bool = true
## Upper bound on GraphNodes. Nodes nearest the roots win; graph_built reports truncation.
var max_nodes:int = 400

## Files the neighbourhood view centres on. Empty = full view. While set, only nodes within
## focus_depth hops of a focus file - in EITHER direction - are drawn: dependencies fan out
## to the right of the focus, dependents to its left. Change via set_focus()/clear_focus().
var focus_paths:PackedStringArray = []
## Hops each way the neighbourhood view reaches. 1 = direct connections only.
var focus_depth:int = 1

var _graph = null
var _nodes_by_path:Dictionary = {}       # {path: DepFileNode}
var _path_by_name:Dictionary = {}        # {StringName: path}
var _name_by_path:Dictionary = {}        # {path: StringName}
var _edges_by_connection:Dictionary = {} # {"from|port|to": Array[DepEdge]}
var _manual_positions:Dictionary = {}    # {path: Vector2} - survives until relayout()
var _visible_kinds:Array = []
var _primary_edges:Array = []
var _secondary_edges:Array = []
var _frames_by_dir:Dictionary = {}       # {dir: GraphFrame}
var _dir_by_path:Dictionary = {}         # {path: dir} - which frame owns each node
var _next_id:int = 0


func _ready() -> void:
	minimap_enabled = true
	show_grid = true
	right_disconnects = false
	connection_lines_curvature = 0.4
	connection_lines_antialiased = true
	connection_lines_thickness = LINE_THICKNESS
	# well below GraphEdit's own floor: the folder tree of a whole addon is a tall strip, and a
	# view that cannot zoom out far enough to show it is no overview at all
	zoom_min = 0.02
	zoom_max = 2.0
	node_selected.connect(_on_node_selected)
	node_deselected.connect(_on_node_deselected)


# --- public API ------------------------------------------------------------------------

## `paths` may be a String, Array or PackedStringArray. Scans, then renders.
func set_files(paths) -> void:
	var roots = _as_path_array(paths)
	if roots.is_empty():
		clear_graph()
		return

	var collector = Scanner.open_many(roots)
	collector.max_depth = scan_max_depth
	collector.follow_load = scan_follow_load
	collector.follow_extensions = scan_follow_extensions.duplicate()
	collector.ignore_dir_paths = scan_ignore_dir_paths.duplicate()
	collector.ignore_dir_names = scan_ignore_dir_names.duplicate()
	collector.include_missing = show_missing
	collector.ignore_line_tags = scan_ignore_line_tags.duplicate()
	for tag:String in scan_tag_handlers:
		collector.add_tag_handler(tag, scan_tag_handlers[tag])

	set_graph(collector.get_graph())


## Render a DepGraph the caller already built, so nothing is scanned twice.
func set_graph(dep_graph) -> void:
	_graph = dep_graph
	_manual_positions.clear()
	_rebuild()


func get_dep_graph():
	return _graph


func clear_graph() -> void:
	clear_connections()
	_clear_frames()
	# removed before freeing: queue_free() defers, and the rebuild reuses these names from n0 -
	# a child still holding one gets the newcomer silently renamed, and every connection made
	# against the expected name then misses
	for node in _nodes_by_path.values():
		remove_child(node)
		node.queue_free()
	_nodes_by_path.clear()
	_path_by_name.clear()
	_name_by_path.clear()
	_edges_by_connection.clear()
	_primary_edges.clear()
	_secondary_edges.clear()
	_next_id = 0


## Drop manual node positions and lay the graph out again.
func relayout() -> void:
	_manual_positions.clear()
	if _graph != null:
		_apply_layout()


## Restrict the view to the neighbourhood of `paths`: everything within focus_depth hops,
## both directions. `depth` of -1 keeps the current focus_depth. Empty paths restores the
## full view. Manual positions are dropped - they mean nothing across a node-set change.
func set_focus(paths, depth:int = -1) -> void:
	focus_paths = PackedStringArray(_as_path_array(paths))
	if depth >= 0:
		focus_depth = depth
	_manual_positions.clear()
	if _graph != null:
		_rebuild()


func clear_focus() -> void:
	set_focus([])


## Centre the neighbourhood view on the current GraphEdit selection.
func focus_on_selection(depth:int = -1) -> void:
	set_focus(get_selected_paths(), depth)


## [] shows every kind. Rebuilds rather than just reconnecting: a node's rows ARE its ports,
## so hiding a kind has to remove the row that carried it.
func set_visible_kinds(kinds:Array) -> void:
	_visible_kinds = kinds.duplicate()
	if _graph != null:
		_rebuild()


func set_edge_mode(mode:EdgeMode) -> void:
	edge_mode = mode


func get_visible_kinds() -> Array:
	return _visible_kinds.duplicate()


## Zoom out until the whole graph fits, then centre it. A fresh build otherwise leaves the
## view wherever the scroll happened to be, which on a graph this shape is empty space.
func reset_view() -> void:
	if _nodes_by_path.is_empty():
		return
	_fit_to_graph()
	# GraphEdit clamps scroll_offset against content bounds it has not measured on the frame
	# the nodes are added, so the fit has to be applied again once layout has run
	if is_inside_tree() and not get_tree().process_frame.is_connected(_fit_to_graph):
		get_tree().process_frame.connect(_fit_to_graph, CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _fit_to_graph() -> void:
	if _nodes_by_path.is_empty() or size.x <= 0.0 or size.y <= 0.0:
		return

	var bounds = _graph_bounds()
	var margin = VIEW_MARGIN * KindStyle.get_scale()
	var padded = bounds.grow(margin)
	if padded.size.x <= 0.0 or padded.size.y <= 0.0:
		return

	zoom = clampf(minf(size.x / padded.size.x, size.y / padded.size.y), zoom_min, 1.0)
	scroll_offset = padded.get_center() * zoom - size * 0.5


func _graph_bounds() -> Rect2:
	var rects:Array[Rect2] = []
	for node in _nodes_by_path.values():
		rects.append(Rect2(node.position_offset, node.get_combined_minimum_size()))
	for frame in _frames_by_dir.values():
		rects.append(Rect2(frame.position_offset, frame.size))
	if rects.is_empty():
		return Rect2()

	var bounds = rects[0]
	for i in range(1, rects.size()):
		bounds = bounds.merge(rects[i])
	return bounds


func focus_path(path:String) -> void:
	var node = _nodes_by_path.get(path)
	if node == null:
		return
	for other in _nodes_by_path.values():
		other.selected = false
	node.selected = true
	# scroll_offset is in graph space scaled by zoom; centre the node in the viewport
	scroll_offset = node.position_offset * zoom - (size * 0.5) + (node.size * zoom * 0.5)
	file_selected.emit(path)


func get_selected_paths() -> PackedStringArray:
	var out = PackedStringArray()
	for path:String in _nodes_by_path:
		if _nodes_by_path[path].selected:
			out.append(path)
	return out


func get_node_path_at(graph_node_name:StringName) -> String:
	return _path_by_name.get(graph_node_name, "")


# --- build -----------------------------------------------------------------------------

# Edges are decided BEFORE the nodes are built: a node's rows are its ports, and a port has
# to exist for every kind that will be drawn through it - no more and no fewer.
func _rebuild() -> void:
	clear_graph()
	if _graph == null:
		return

	var paths = _paths_to_show()
	var shown = _prune_unreachable(paths)
	var truncated = shown.size() < _graph.nodes.size()
	if not focus_paths.is_empty():
		# neighbourhood view: keep only what lies within focus_depth hops of a focus file
		var near = Layout.neighborhood_dist(_graph, focus_paths, focus_depth)
		for path in shown.keys():
			if not near.has(path):
				shown.erase(path)

	_primary_edges = _select_edges(shown)
	_secondary_edges = [] if edge_mode == EdgeMode.ALL else _select_secondary(shown, _primary_edges)

	var kinds = _kind_sets(_primary_edges + _secondary_edges)
	for path:String in paths:
		if not shown.has(path):
			continue
		var sets = kinds.get(path, {"in": {}, "out": {}})
		_add_file_node(path, _graph.nodes[path], sets["in"], sets["out"])
	if show_unresolved:
		_add_unresolved_nodes(shown, kinds)

	_apply_layout()
	_connect_edges()
	reset_view()
	graph_built.emit(_nodes_by_path.size(), truncated)


## {path: true} for the nodes that keep a reason to be on screen. A node whose every incoming
## edge was filtered out - by kind, by the hub flag, by the node cap - has nothing explaining
## why it is there, and the removal cascades to whatever only it referenced.
func _prune_unreachable(paths:Array) -> Dictionary:
	var allowed = {}
	for path:String in paths:
		allowed[path] = true

	var shown:Dictionary = _graph.get_reachable(_edge_drawable.bind(allowed))
	for path:String in shown.keys():
		if not allowed.has(path):
			shown.erase(path) # a root the filters dropped
	return shown


## The edges that get a full-strength line. In TREE mode the graph picks each node's parent
## from the edges this panel would draw, so the choice can never leave a node unconnected.
func _select_edges(shown:Dictionary) -> Array:
	var out:Array = []
	if edge_mode == EdgeMode.TREE:
		var parents = _graph.get_tree_parents(_edge_drawable.bind(shown))
		for path:String in parents:
			out.append(parents[path])
		return out

	for edge in _graph.edges:
		if _edge_drawable(edge, shown):
			out.append(edge)
	return out


## Everything the tree left out, drawn faint so the extra structure is visible but quiet.
func _select_secondary(shown:Dictionary, primary:Array) -> Array:
	if not show_secondary_edges:
		return []
	var taken = {}
	for edge in primary:
		taken[edge] = true
	var out:Array = []
	for edge in _graph.edges:
		if not taken.has(edge) and _edge_drawable(edge, shown):
			out.append(edge)
	return out


func _edge_drawable(edge, shown:Dictionary) -> bool:
	if not _kind_visible(edge.kind):
		return false
	if not shown.has(edge.from):
		return false
	if edge.to == "":
		return show_unresolved
	return shown.has(edge.to)


## {path: {"in": {kind:true}, "out": {kind:true}}} over the edges that will be drawn.
func _kind_sets(edges:Array) -> Dictionary:
	var sets = {}
	for edge in edges:
		var to_key = edge.to if edge.to != "" else "unresolved:" + edge.raw
		if not sets.has(edge.from):
			sets[edge.from] = {"in": {}, "out": {}}
		if not sets.has(to_key):
			sets[to_key] = {"in": {}, "out": {}}
		sets[edge.from]["out"][edge.kind] = true
		sets[to_key]["in"][edge.kind] = true
	return sets


# Nearest the roots wins when the cap bites, so a truncated graph is still the useful part.
func _paths_to_show() -> Array:
	var paths:Array = []
	for path:String in _graph.nodes:
		var node = _graph.nodes[path]
		if not show_missing and not node.exists:
			continue
		if hide_namespace_hubs and node.is_namespace_hub:
			continue
		paths.append(path)

	if max_nodes > 0 and paths.size() > max_nodes:
		paths.sort_custom(_compare_by_depth)
		paths = paths.slice(0, max_nodes)
	return paths


func _compare_by_depth(a:String, b:String) -> bool:
	var da:int = _graph.nodes[a].depth
	var db:int = _graph.nodes[b].depth
	if da == db:
		return a < b
	return da < db


func _add_file_node(path:String, dep_node, in_kinds:Dictionary, out_kinds:Dictionary) -> void:
	var node = DepFileNode.create(path, dep_node, "", in_kinds, out_kinds)
	if path in focus_paths:
		node.mark_focused()
	var node_name = StringName("n%d" % _next_id)
	_next_id += 1
	node.name = node_name
	node.activated.connect(_on_node_activated)
	add_child(node)
	_nodes_by_path[path] = node
	_path_by_name[node_name] = path
	_name_by_path[path] = node_name


# One stub per distinct unresolved target, keyed so several dead references to the same raw
# text collapse into a single node.
func _add_unresolved_nodes(shown:Dictionary, kinds:Dictionary) -> void:
	for edge in _graph.unresolved:
		if not shown.has(edge.from):
			continue
		var key = "unresolved:" + edge.raw
		if _nodes_by_path.has(key):
			continue
		if not kinds.has(key):
			continue # its edge was filtered out, so nothing would point at the stub
		var node = DepFileNode.create(key, null, edge.raw, kinds[key]["in"], {})
		var node_name = StringName("n%d" % _next_id)
		_next_id += 1
		node.name = node_name
		add_child(node)
		_nodes_by_path[key] = node
		_path_by_name[node_name] = key
		_name_by_path[key] = node_name


func _apply_layout() -> void:
	var scale = KindStyle.get_scale()
	var sizes = {}
	for path:String in _nodes_by_path:
		# the real minimum is available as soon as the children are in - no frame to wait for -
		# and it beats the estimate, which does not know the theme's panel margins
		var size:Vector2 = _nodes_by_path[path].get_combined_minimum_size()
		if size.x <= 0.0 or size.y <= 0.0:
			size = DepFileNode.estimate_size(_graph.nodes.get(path))
		sizes[path] = size

	var positions:Dictionary
	if node_layout == LayoutMode.FOLDER:
		# h_gap/v_gap are sized for connection lines running between columns; files stacked
		# inside a frame are not read that way, so FOLDER gets its own spacing entirely
		var result = Layout.compute_by_folder(_layout_source(), sizes, {
			"file_gap": folder_file_gap * scale,
			"gap": folder_gap * scale,
			"row_gap": folder_row_gap * scale,
			"padding": folder_padding * scale,
			"title_height": Layout.FOLDER_DEFAULTS.title_height * scale,
			"max_column_height": Layout.FOLDER_DEFAULTS.max_column_height * scale,
		})
		positions = result.positions
		_dir_by_path = result.dirs
		_build_frames(result.folders, result.titles)
	else:
		if not focus_paths.is_empty():
			# neighbourhood view: focus at column 0, dependents left, dependencies right
			positions = Layout.compute_neighborhood(_layout_source(), focus_paths, focus_depth, sizes, {"h_gap": h_gap * scale, "v_gap": v_gap * scale})
		else:
			positions = Layout.compute(_layout_source(), sizes, {"h_gap": h_gap * scale, "v_gap": v_gap * scale})

	for path:String in _nodes_by_path:
		if _manual_positions.has(path):
			_nodes_by_path[path].position_offset = _manual_positions[path]
		elif positions.has(path):
			_nodes_by_path[path].position_offset = positions[path]

	if node_layout == LayoutMode.FOLDER:
		_attach_frames()


# One GraphFrame per directory, laid out flat - a folder's column already says how deep it
# sits, so the frames do not need to nest. Positioned and sized from the layout rather than
# left to autoshrink, so a folder keeps its slot even while its nodes are being dragged.
func _build_frames(folders:Dictionary, titles:Dictionary) -> void:
	_clear_frames()
	var index = 0
	for dir:String in folders:
		var frame = GraphFrame.new()
		frame.name = StringName("f%d" % index)
		frame.title = titles.get(dir, dir.trim_prefix("res://"))
		frame.tooltip_text = dir
		frame.autoshrink_enabled = false
		frame.tint_color_enabled = true
		frame.tint_color = KindStyle.get_folder_tint(_dir_depth(dir))
		frame.draggable = true
		frame.selectable = false
		var rect:Rect2 = folders[dir]
		frame.position_offset = rect.position
		frame.size = rect.size
		add_child(frame)
		_frames_by_dir[dir] = frame
		index += 1


# Tint by directory depth rather than by build order, so a column reads as one shade and the
# nesting level is legible without following the frames back to their parent.
static func _dir_depth(dir:String) -> int:
	return dir.trim_prefix("res://").split("/", false).size()


func _attach_frames() -> void:
	for path:String in _nodes_by_path:
		var frame = _frames_by_dir.get(_dir_by_path.get(path, ""))
		if frame != null:
			attach_graph_element_to_frame(_name_by_path[path], frame.name)


func _clear_frames() -> void:
	for frame in _frames_by_dir.values():
		for element in get_attached_nodes_of_frame(frame.name):
			detach_graph_element_from_frame(element)
		remove_child(frame)
		frame.queue_free()
	_frames_by_dir.clear()
	_dir_by_path.clear()


# Layout has to see exactly what is on screen and nothing else - a pruned node still holding a
# slot in its column leaves a gap with nothing in it.
func _layout_source():
	return _ViewGraph.new(_graph, _nodes_by_path)


func _connect_edges() -> void:
	clear_connections()
	_edges_by_connection.clear()

	for edge in _primary_edges:
		_connect_one(edge)
	for edge in _secondary_edges:
		_connect_one(edge)


## Returns the connection key, or "" if the edge could not be drawn.
func _connect_one(edge) -> String:
	var from_name = _name_by_path.get(edge.from)
	if from_name == null:
		return ""
	var to_key = edge.to if edge.to != "" else "unresolved:" + edge.raw
	var to_name = _name_by_path.get(to_key)
	if to_name == null:
		return ""

	var from_port:int = _nodes_by_path[edge.from].out_port_of_kind.get(edge.kind, 0)
	var to_port:int = _nodes_by_path[to_key].in_port_of_kind.get(edge.kind, 0)
	var key = "%s|%d|%s|%d" % [from_name, from_port, to_name, to_port]
	if not _edges_by_connection.has(key):
		_edges_by_connection[key] = []
		connect_node(from_name, from_port, to_name, to_port)
	_edges_by_connection[key].append(edge)
	return key


func _kind_visible(kind:int) -> bool:
	return _visible_kinds.is_empty() or kind in _visible_kinds


# --- interaction -----------------------------------------------------------------------

func _on_node_selected(node:Node) -> void:
	file_selected.emit(_path_by_name.get(node.name, ""))


func _on_node_deselected(_node:Node) -> void:
	if get_selected_paths().is_empty():
		file_selected.emit("")


func _on_node_activated(path:String) -> void:
	file_activated.emit(path)


func _gui_input(event:InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var edges = _edges_at(event.position)
	if edges.is_empty():
		return
	edge_activated.emit(edges)
	accept_event()


func _make_custom_tooltip(_for_text:String) -> Object:
	return null


func _get_tooltip(at_position:Vector2) -> String:
	var edges = _edges_at(at_position)
	if edges.is_empty():
		return ""
	return _describe_edges(edges)


func _edges_at(local_position:Vector2) -> Array:
	var connection = get_closest_connection_at_point(local_position, 6.0)
	if connection.is_empty():
		return []
	var key = "%s|%d|%s|%d" % [connection.from_node, connection.from_port, connection.to_node, connection.to_port]
	return _edges_by_connection.get(key, [])


# "preload · lines 12, 40" - the line numbers are the reason the DepEdge list is kept.
func _describe_edges(edges:Array) -> String:
	var first = edges[0]
	var from_file:String = first.from.get_file()
	var to_file:String = first.to.get_file() if first.to != "" else first.raw
	var lines:Array = []
	for edge in edges:
		if edge.line_no > 0 and not edge.line_no in lines:
			lines.append(edge.line_no)
	lines.sort()

	var text = "%s → %s\n%s" % [from_file, to_file, KindStyle.get_label(first.kind)]
	if lines.size() == 1:
		text += " · line %d" % lines[0]
	elif lines.size() > 1:
		text += " · lines %s" % ", ".join(PackedStringArray(lines.map(func(l): return str(l))))
	return text


func _notification(what:int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_store_manual_positions()


func _store_manual_positions() -> void:
	for path:String in _nodes_by_path:
		_manual_positions[path] = _nodes_by_path[path].position_offset


# --- helpers ---------------------------------------------------------------------------

static func _as_path_array(paths) -> Array:
	if paths is String or paths is StringName:
		return [String(paths)] if String(paths) != "" else []
	if paths is PackedStringArray:
		return Array(paths)
	if paths is Array:
		var out:Array = []
		for p in paths:
			if p is String or p is StringName:
				if String(p) != "":
					out.append(String(p))
		return out
	return []


## Opens the panel in a self-freeing Window. For previewing while developing - real hosting
## is the caller's job.
##
##     script call --path=res://<this file> preview_window -- res://addons/foo/plugin.gd
static func preview_window(paths = []) -> Window:
	if paths is String:
		paths = [paths]
	var panel = new()
	var window = Window.new()
	window.title = "Dependency Graph"
	window.size = Vector2i(1400, 900) * int(maxf(KindStyle.get_scale(), 1.0))
	window.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_SCREEN_WITH_MOUSE_FOCUS
	window.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	window.close_requested.connect(window.queue_free)
	
	panel.set_edge_mode(EdgeMode.TREE)
	panel.v_gap = 50
	#panel.node_layout = LayoutMode.FOLDER
	
	var parent = null
	var ed_int = KindStyle.get_editor_interface()
	if ed_int != null:
		parent = ed_int.get_base_control()
	if parent == null:
		printerr("GraphUI.preview_window: no editor base control to parent to.")
		window.queue_free()
		return null

	parent.add_child(window)
	window.show()
	panel.set_files(paths)
	return window


## The drawn subset of the graph, with the unresolved stubs folded in as ordinary nodes one
## column right of whatever referenced them. Layout reads this instead of the real DepGraph.
class _ViewGraph:
	var nodes:Dictionary = {}

	func _init(source, shown:Dictionary) -> void:
		for path:String in source.nodes:
			if shown.has(path):
				nodes[path] = source.nodes[path]

		for edge in source.unresolved:
			var key = "unresolved:" + edge.raw
			if not shown.has(key):
				continue
			var parent = nodes.get(edge.from)
			var depth:int = parent.depth + 1 if parent != null else 0
			var stub = nodes.get(key)
			if stub == null:
				stub = _StubNode.new(key, depth, String(edge.from).get_base_dir())
				nodes[key] = stub
			else:
				stub.depth = mini(stub.depth, depth)
			stub.in_edges.append(edge)


## The slice of DepNode that Layout reads. A stub's key is not a real path, so the folder
## layout is told to park it beside the file that referenced it.
class _StubNode:
	var path:String
	var depth:int
	var dir:String
	var in_edges:Array = []
	var out_edges:Array = []

	func _init(_path:String, _depth:int, _dir:String) -> void:
		path = _path
		depth = _depth
		dir = _dir

	func get_dir() -> String:
		return dir
