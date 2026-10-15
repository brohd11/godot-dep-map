## Layered layout for a DepGraph. Pure - no Control is touched, which is what makes it
## testable headless.
##
## Column is the node's LONGEST path from a root (depth_mode "max", the default): every edge
## then satisfies depth(to) > depth(from), so dependencies flow strictly left to right and no
## line ever doubles back. The scanner's DepNode.depth - the SHORTEST hop count - is still
## available as depth_mode "min"; it reads shallower, but a node reached both directly and
## via a long chain drags its deep incoming edges back across the graph. Row order inside a
## column comes from the barycentre of each node's parents - the cheap half of Sugiyama -
## which is what stops the connection lines turning into a hairball.

const DEFAULTS = {
	"h_gap": 90.0,   # between columns
	"v_gap": 24.0,   # between nodes in a column
	"sweeps": 2,     # barycentre refinement passes, each one down then up
	"depth_mode": "max", # "max" layers by longest path, "min" by the scanner's depth
}

const FOLDER_DEFAULTS = {
	"padding": 40.0,            # inside a folder's frame, around its nodes
	"gap": 120.0,               # between columns of folders
	# Between sibling folders. Much smaller than the column gap: it is paid once per folder in
	# the whole tree, and a file tree has a lot of folders.
	"row_gap": 40.0,
	# Files inside a frame are stacked, not connected through the space between them, so this
	# is deliberately not the layered layout's v_gap - that one is sized for connection lines.
	"file_gap": 24.0,
	"max_column_height": 1600.0,# a folder taller than this wraps into another sub-column
	"title_height": 48.0,       # headroom a GraphFrame's title bar needs
}

## Narrowest a folder frame may be, as a fraction of a nominal node width. Branch levels hold
## no files of their own and would otherwise collapse to a sliver their title cannot fit in.
const MIN_WIDTH_RATIO = 0.75


## `sizes` is {path: Vector2}; the panel estimates these so nothing has to wait a frame.
## Returns {path: Vector2} positions. Paths absent from `sizes` fall back to a nominal size.
static func compute(dep_graph, sizes:Dictionary, opts:Dictionary = {}) -> Dictionary:
	var h_gap:float = opts.get("h_gap", DEFAULTS.h_gap)
	var v_gap:float = opts.get("v_gap", DEFAULTS.v_gap)
	var sweeps:int = opts.get("sweeps", DEFAULTS.sweeps)

	var columns:Array
	if opts.get("depth_mode", DEFAULTS.depth_mode) == "min":
		columns = _build_columns(dep_graph)
	else:
		columns = _build_columns_max(dep_graph)
	if columns.is_empty():
		return {}

	var order = _order_columns(columns, dep_graph, sweeps)
	return _assign_positions(order, sizes, h_gap, v_gap)


## Column index per node, keyed by depth. Returns Array[Array[String]] indexed by column.
static func _build_columns(dep_graph) -> Array:
	var by_depth = {}
	var max_depth = 0
	for path:String in dep_graph.nodes:
		var depth:int = dep_graph.nodes[path].depth
		if depth < 0:
			depth = 0
		max_depth = maxi(max_depth, depth)
		if not by_depth.has(depth):
			by_depth[depth] = []
		by_depth[depth].append(path)

	var columns:Array = []
	for i in max_depth + 1:
		var col:Array = by_depth.get(i, [])
		col.sort() # deterministic starting order; the barycentre passes take it from here
		columns.append(col)
	return columns


## Column index per node, keyed by the LONGEST path from a source. Longest path is only
## defined on a DAG, and dependency cycles are legal (mutual preloads), so strongly
## connected components are condensed first and every node in a cycle shares one column.
## Computed from the edges alone, so it works on the panel's view graph, stubs included.
static func _build_columns_max(dep_graph) -> Array:
	if dep_graph.nodes.is_empty():
		return []

	var comp = _strongly_connected(dep_graph) # {path: component id}
	var comp_count := 0
	for path in comp:
		comp_count = maxi(comp_count, comp[path] + 1)

	var preds:Array = [] # per component, the set of components feeding it
	for i in comp_count:
		preds.append({})
	for path:String in dep_graph.nodes:
		for edge in dep_graph.nodes[path].in_edges:
			if comp.has(edge.from) and comp[edge.from] != comp[path]:
				preds[comp[path]][comp[edge.from]] = true

	var memo = {}
	var by_depth = {}
	var max_depth := 0
	for path:String in dep_graph.nodes:
		var depth := _component_depth(comp[path], preds, memo)
		max_depth = maxi(max_depth, depth)
		if not by_depth.has(depth):
			by_depth[depth] = []
		by_depth[depth].append(path)

	var columns:Array = []
	for i in max_depth + 1:
		var col:Array = by_depth.get(i, [])
		col.sort()
		columns.append(col)
	return columns


## depth[c] = 0 for sources, else 1 + max(depth of its predecessors). The condensed graph
## is a DAG by construction, so the memoized walk cannot re-enter a component.
static func _component_depth(c:int, preds:Array, memo:Dictionary) -> int:
	if memo.has(c):
		return memo[c]
	var depth := 0
	for p in preds[c]:
		depth = maxi(depth, _component_depth(p, preds, memo) + 1)
	memo[c] = depth
	return depth


## Tarjan's algorithm. Returns {path: component id}. Edges to nodes outside the graph -
## pruned away by the panel, or unresolved targets - are not part of any cycle here.
static func _strongly_connected(dep_graph) -> Dictionary:
	var state = {
		"index_of": {}, "low": {}, "on_stack": {}, "stack": [],
		"comp": {}, "next": 0, "comp_next": 0,
	}
	for path:String in dep_graph.nodes:
		if not state.index_of.has(path):
			_tarjan_visit(path, dep_graph, state)
	return state.comp


static func _tarjan_visit(path:String, dep_graph, state:Dictionary) -> void:
	state.index_of[path] = state.next
	state.low[path] = state.next
	state.next += 1
	state.stack.append(path)
	state.on_stack[path] = true

	for edge in dep_graph.nodes[path].out_edges:
		var to:String = edge.to
		if to == "" or not dep_graph.nodes.has(to):
			continue
		if not state.index_of.has(to):
			_tarjan_visit(to, dep_graph, state)
			state.low[path] = mini(state.low[path], state.low[to])
		elif state.on_stack.has(to):
			state.low[path] = mini(state.low[path], state.index_of[to])

	if state.low[path] == state.index_of[path]:
		while true:
			var w = state.stack.pop_back()
			state.on_stack.erase(w)
			state.comp[w] = state.comp_next
			if w == path:
				break
		state.comp_next += 1


## Positions for the neighbourhood view: the focus file(s) at column 0, their dependencies
## counting up to the right, their dependents counting down to the left, out to max_depth
## hops each way. Same column ordering and spacing as the full layered layout.
static func compute_neighborhood(dep_graph, focus:Array, max_depth:int, sizes:Dictionary, opts:Dictionary = {}) -> Dictionary:
	var h_gap:float = opts.get("h_gap", DEFAULTS.h_gap)
	var v_gap:float = opts.get("v_gap", DEFAULTS.v_gap)
	var sweeps:int = opts.get("sweeps", DEFAULTS.sweeps)

	var dist = neighborhood_dist(dep_graph, focus, max_depth)
	if dist.is_empty():
		return {}

	var by_column = {}
	for path in dist:
		var d:int = dist[path]
		if not by_column.has(d):
			by_column[d] = []
		by_column[d].append(path)

	var keys:Array = by_column.keys()
	keys.sort()
	var columns:Array = []
	for d in keys:
		var col:Array = by_column[d]
		col.sort()
		columns.append(col)

	var order = _order_columns(columns, dep_graph, sweeps)
	return _assign_positions(order, sizes, h_gap, v_gap)


## Signed hop distance from the focus set: dependencies count up (they sit right of the
## focus), dependents count down. A node reachable from both sides keeps the shorter one;
## a tie keeps whichever side was found first, so the result is deterministic. `max_depth`
## bounds each side independently; negative means unbounded. {path: signed hops}.
static func neighborhood_dist(dep_graph, focus:Array, max_depth:int) -> Dictionary:
	var dist = {}
	var queue:Array = []
	for path in focus:
		if dep_graph.nodes.has(path) and not dist.has(path):
			dist[path] = 0
			queue.append(path)

	while not queue.is_empty():
		var current:String = queue.pop_front()
		var d:int = dist[current]
		if max_depth >= 0 and absi(d) >= max_depth:
			continue
		var node = dep_graph.nodes[current]
		for edge in node.out_edges:
			_offer_hop(dist, queue, dep_graph, edge.to, d + 1)
		for edge in node.in_edges:
			_offer_hop(dist, queue, dep_graph, edge.from, d - 1)
	return dist


static func _offer_hop(dist:Dictionary, queue:Array, dep_graph, path:String, d:int) -> void:
	if path == "" or not dep_graph.nodes.has(path):
		return
	if dist.has(path):
		# a shorter route from the other side wins, and its neighbours deserve the update
		if absi(d) < absi(dist[path]):
			dist[path] = d
			queue.append(path)
		return
	dist[path] = d
	queue.append(path)


static func _order_columns(columns:Array, dep_graph, sweeps:int) -> Array:
	if columns.size() < 2:
		return columns

	for _i in maxi(sweeps, 0):
		for c in range(1, columns.size()):
			columns[c] = _sort_by_barycentre(columns[c], columns[c - 1], dep_graph, true)
		for c in range(columns.size() - 2, -1, -1):
			columns[c] = _sort_by_barycentre(columns[c], columns[c + 1], dep_graph, false)
	return columns


# Orders `column` by the mean row index of its neighbours in `reference`. Nodes with no
# neighbour there keep their current relative position rather than collapsing to the top.
static func _sort_by_barycentre(column:Array, reference:Array, dep_graph, use_parents:bool) -> Array:
	if column.size() < 2:
		return column

	var ref_index = {}
	for i in reference.size():
		ref_index[reference[i]] = float(i)

	var keyed:Array = []
	for i in column.size():
		var path:String = column[i]
		var node = dep_graph.nodes.get(path)
		var sum := 0.0
		var count := 0
		if node != null:
			var edges:Array = node.in_edges if use_parents else node.out_edges
			for edge in edges:
				var other:String = edge.from if use_parents else edge.to
				if ref_index.has(other):
					sum += ref_index[other]
					count += 1
		# no neighbour to align to: hold position, scaled into the reference's index space
		var key:float = sum / count if count > 0 else _hold_key(i, column.size(), reference.size())
		keyed.append({"path": path, "key": key, "idx": i})

	keyed.sort_custom(_compare_keyed)
	var out:Array = []
	for entry in keyed:
		out.append(entry.path)
	return out


static func _hold_key(index:int, column_size:int, reference_size:int) -> float:
	if column_size <= 1:
		return 0.0
	return float(index) / float(column_size - 1) * maxf(float(reference_size - 1), 0.0)


static func _compare_keyed(a:Dictionary, b:Dictionary) -> bool:
	if a.key == b.key:
		if a.idx == b.idx:
			return a.path < b.path
		return a.idx < b.idx
	return a.key < b.key


static func _assign_positions(columns:Array, sizes:Dictionary, h_gap:float, v_gap:float) -> Dictionary:
	var fallback = Vector2(220.0, 60.0)

	var column_heights:Array[float] = []
	var tallest := 0.0
	for col:Array in columns:
		var height := 0.0
		for path:String in col:
			height += _size_of(sizes, path, fallback).y + v_gap
		height = maxf(height - v_gap, 0.0)
		column_heights.append(height)
		tallest = maxf(tallest, height)

	var positions = {}
	var x := 0.0
	for c in columns.size():
		var col:Array = columns[c]
		var widest := 0.0
		# columns are centred against the tallest so the graph reads as a band, not a staircase
		var y := (tallest - column_heights[c]) * 0.5
		for path:String in col:
			var size = _size_of(sizes, path, fallback)
			positions[path] = Vector2(x, y)
			y += size.y + v_gap
			widest = maxf(widest, size.x)
		x += widest + h_gap

	return positions


static func _size_of(sizes:Dictionary, path:String, fallback:Vector2) -> Vector2:
	var size = sizes.get(path)
	if size is Vector2 and size.x > 0.0 and size.y > 0.0:
		return size
	return fallback


## Groups files by their directory and lays the directories out as the tree they are, read
## left to right: a folder's column is its depth in that tree, and the vertical axis is
## reserved for siblings. The depth layering falls apart past a few hundred nodes - every
## column looks alike and there is nothing to navigate by - whereas this draws the project's
## own structure, which the reader already knows how to move around in.
##
## Returns {"positions": {path: Vector2}, "folders": {dir: Rect2}, "titles": {dir: String},
## "dirs": {path: dir}}; the rects are what the panel sizes its GraphFrames from, and `dirs`
## is which frame each file belongs to.
static func compute_by_folder(dep_graph, sizes:Dictionary, opts:Dictionary = {}) -> Dictionary:
	var file_gap:float = opts.get("file_gap", FOLDER_DEFAULTS.file_gap)
	var padding:float = opts.get("padding", FOLDER_DEFAULTS.padding)
	var folder_gap:float = opts.get("gap", FOLDER_DEFAULTS.gap)
	var row_gap:float = opts.get("row_gap", FOLDER_DEFAULTS.row_gap)
	var max_height:float = opts.get("max_column_height", FOLDER_DEFAULTS.max_column_height)
	var title_height:float = opts.get("title_height", FOLDER_DEFAULTS.title_height)
	var fallback = Vector2(220.0, 60.0)

	var by_folder = _group_by_folder(dep_graph)
	if by_folder.is_empty():
		return {"positions": {}, "folders": {}, "titles": {}, "dirs": {}}

	var roots = _build_dir_tree(by_folder)
	# each folder's own frame, laid out at the origin
	for root in roots:
		_measure_tree(root, by_folder, sizes, file_gap, padding, max_height, title_height, fallback)
	# a column is as wide as its widest folder, so the next column clears all of them
	var x_of_column = _column_offsets(roots, folder_gap)

	# subtrees are stacked disjointly and each parent centred against its children
	var out = {"positions": {}, "folders": {}, "titles": {}, "dirs": {}}
	var y := 0.0
	for root in roots:
		_measure_spans(root, row_gap)
		_assign_rows(root, y, row_gap)
		y += root.span + row_gap
		_collect_tree(root, x_of_column, out)
	return out


# One folder at the origin: files stacked by name below the frame's title bar, wrapping into
# another sub-column once the stack gets taller than max_height. A folder with no files of its
# own is still a real level of the tree, so it keeps a minimum frame to carry its title.
static func _layout_folder(members:Array, sizes:Dictionary, file_gap:float, padding:float, max_height:float, title_height:float, fallback:Vector2) -> Dictionary:
	var sorted:Array = members.duplicate()
	sorted.sort()
	var top := padding + title_height
	var positions = {}
	var column_x := padding
	var y := top
	var widest := 0.0
	var right := padding + fallback.x * MIN_WIDTH_RATIO
	var bottom := top

	for path:String in sorted:
		var size = _size_of(sizes, path, fallback)
		if y > top and y + size.y > max_height:
			column_x += widest + file_gap
			y = top
			widest = 0.0
		positions[path] = Vector2(column_x, y)
		widest = maxf(widest, size.x)
		right = maxf(right, column_x + size.x)
		bottom = maxf(bottom, y + size.y)
		y += size.y + file_gap

	return {"positions": positions, "size": Vector2(right + padding, bottom + padding)}


# get_dir() rather than path.get_base_dir(): an unresolved stub's key is not a real path, and
# the node is the only thing that knows where it should be parked.
static func _group_by_folder(dep_graph) -> Dictionary:
	var by_folder = {}
	for path:String in dep_graph.nodes:
		var dir:String = dep_graph.nodes[path].get_dir()
		if not by_folder.has(dir):
			by_folder[dir] = []
		by_folder[dir].append(path)
	return by_folder


# --- directory tree --------------------------------------------------------------------

## Display nodes for the roots. Every directory level up to the scheme root is materialised
## first, then the corridors are collapsed away - which is what leaves "res://" out front only
## when the files genuinely diverge under it. Normally a forest of one; a scan spanning res://
## and user:// gets a tree each, stacked.
static func _build_dir_tree(by_folder:Dictionary) -> Array:
	var children = {} # {dir: {child_dir: true}}
	var tops = {}
	for dir:String in by_folder:
		var current:String = dir
		while true:
			if not children.has(current):
				children[current] = {}
			var parent:String = current.get_base_dir()
			if parent == "" or parent == current:
				tops[current] = true
				break
			if not children.has(parent):
				children[parent] = {}
			children[parent][current] = true
			current = parent

	var top_dirs:Array = tops.keys()
	top_dirs.sort()
	var roots:Array = []
	for top:String in top_dirs:
		roots.append(_display_node(top, children, by_folder, []))
	return roots


# A level with no files of its own and one way down is a corridor, not a room: it merges into
# its child and contributes a segment to the title instead of a whole column.
static func _display_node(dir:String, children:Dictionary, by_folder:Dictionary, prefix:Array) -> Dictionary:
	var parts:Array = prefix.duplicate()
	var current:String = dir
	while not by_folder.has(current) and children[current].size() == 1:
		_append_segment(parts, current)
		current = children[current].keys()[0]
	_append_segment(parts, current)

	var kid_dirs:Array = children[current].keys()
	kid_dirs.sort()
	var kids:Array = []
	for kid:String in kid_dirs:
		kids.append(_display_node(kid, children, by_folder, []))

	return {
		"dir": current,
		"title": "/".join(PackedStringArray(parts)) if not parts.is_empty() else current,
		"children": kids,
		"column": 0,
		"size": Vector2.ZERO,
		"offsets": {},
		"y": 0.0,
		"span": 0.0,
		"children_span": 0.0,
	}


# A scheme root - "res://" - has no last segment, and adds nothing to a title that already
# names the directories under it, so it is dropped rather than joined in.
static func _append_segment(parts:Array, dir:String) -> void:
	var name = dir.get_file()
	if name != "":
		parts.append(name)


static func _measure_tree(node:Dictionary, by_folder:Dictionary, sizes:Dictionary, file_gap:float, padding:float, max_height:float, title_height:float, fallback:Vector2, column:int = 0) -> void:
	node.column = column
	var block = _layout_folder(by_folder.get(node.dir, []), sizes, file_gap, padding, max_height, title_height, fallback)
	node.offsets = block.positions
	node.size = block.size
	for kid in node.children:
		_measure_tree(kid, by_folder, sizes, file_gap, padding, max_height, title_height, fallback, column + 1)


static func _column_offsets(roots:Array, gap:float) -> PackedFloat32Array:
	var widths:Array[float] = []
	for root in roots:
		_collect_widths(root, widths)
	var offsets = PackedFloat32Array()
	var pen := 0.0
	for width in widths:
		offsets.append(pen)
		pen += width + gap
	return offsets


static func _collect_widths(node:Dictionary, widths:Array[float]) -> void:
	while widths.size() <= node.column:
		widths.append(0.0)
	widths[node.column] = maxf(widths[node.column], node.size.x)
	for kid in node.children:
		_collect_widths(kid, widths)


# Vertical extent of a whole subtree. A parent taller than its children still gets its own
# room, which is what stops it overlapping the sibling subtree above.
static func _measure_spans(node:Dictionary, gap:float) -> float:
	var total := 0.0
	for i in node.children.size():
		if i > 0:
			total += gap
		total += _measure_spans(node.children[i], gap)
	node.children_span = total
	node.span = maxf(node.size.y, total)
	return node.span


static func _assign_rows(node:Dictionary, y_top:float, gap:float) -> void:
	node.y = y_top + (node.span - node.size.y) * 0.5
	var y:float = y_top + (node.span - node.children_span) * 0.5
	for kid in node.children:
		_assign_rows(kid, y, gap)
		y += kid.span + gap


static func _collect_tree(node:Dictionary, x_of_column:PackedFloat32Array, out:Dictionary) -> void:
	var origin = Vector2(x_of_column[node.column], node.y)
	out.folders[node.dir] = Rect2(origin, node.size)
	out.titles[node.dir] = node.title
	for path:String in node.offsets:
		out.positions[path] = origin + node.offsets[path]
		out.dirs[path] = node.dir
	for kid in node.children:
		_collect_tree(kid, x_of_column, out)


## Number of edge crossings in a layout. Only used by the tests and for tuning - the count is
## over ordered column pairs, which is the standard measure for a layered drawing.
static func count_crossings(dep_graph, positions:Dictionary) -> int:
	var row_of = {}
	var by_column = {}
	for path:String in positions:
		var x:float = positions[path].x
		if not by_column.has(x):
			by_column[x] = []
		by_column[x].append(path)

	for x in by_column:
		var col:Array = by_column[x]
		col.sort_custom(func(a, b): return positions[a].y < positions[b].y)
		for i in col.size():
			row_of[col[i]] = i

	var columns_x:Array = by_column.keys()
	columns_x.sort()

	var crossings := 0
	for i in columns_x.size() - 1:
		var pairs:Array = []
		for path:String in by_column[columns_x[i]]:
			var node = dep_graph.nodes.get(path)
			if node == null:
				continue
			for edge in node.out_edges:
				if row_of.has(edge.to) and by_column[columns_x[i + 1]].has(edge.to):
					pairs.append([row_of[path], row_of[edge.to]])
		for a in pairs.size():
			for b in range(a + 1, pairs.size()):
				var p = pairs[a]
				var q = pairs[b]
				if (p[0] - q[0]) * (p[1] - q[1]) < 0:
					crossings += 1
	return crossings
