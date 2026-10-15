@tool
extends EditorScript

## Tests for the dep_graph panel's layered layout.
##
## Layout.compute() is pure - it takes a DepGraph and a size table and returns positions -
## which is the only reason any of this can be checked headless. The panel itself is a
## GraphEdit and needs a live editor; it is verified by eye via preview_window().
##
## Fixtures are written to user:// and scanned with the real collector, so the DepNode.depth
## values under test are the ones the scanner actually produces rather than hand-built stubs.
##
##     load("res://addons/_lib/dep_map/_export_ignore/test/layout_test.gd").run_tests()

const Scanner = preload("uid://dbn0kmkxa7caq") #! resolve DepMap.Scanner
const Layout = preload("res://addons/_lib/dep_map/src/graph_ui/layout.gd")
const DepFileNode = preload("res://addons/_lib/dep_map/src/graph_ui/dep_file_node.gd")

const DIR = "user://alib_dep_graph_tests/"
const NODE_SIZE = Vector2(200, 60)

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_reset_dir()

	_test_empty()
	_test_columns_match_depth()
	_test_roots_in_first_column()
	_test_no_overlap_in_column()
	_test_deterministic()
	_test_sizes_respected()
	_test_diamond_child_between_parents()
	_test_barycentre_reduces_crossings()
	_test_max_depth_pushes_shortcut_node_right()
	_test_max_depth_cycle_shares_column()
	_test_max_depth_opt_min_keeps_old_columns()
	_test_neighborhood_dist_limits_depth()
	_test_neighborhood_columns_around_focus()
	_test_neighborhood_prefers_shorter_side()
	_test_estimate_size_tracks_kinds()
	_test_folder_tree_shape()
	_test_folder_corridor_collapse()
	_test_folder_column_wrap()

	_reset_dir()

	var output:Array[String] = []
	output.append("graph_ui layout: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	var res = run_tests()
	print("\n".join(res.output))


# --- cases -------------------------------------------------------------------------------

static func _test_empty() -> void:
	var graph = Scanner.open_many([]).get_graph()
	_check("empty: no positions", Layout.compute(graph, {}), {})


static func _test_columns_match_depth() -> void:
	var c = _w("col_c.gd", "extends RefCounted\n")
	var b = _w("col_b.gd", 'const C = preload("%s")\n' % c)
	var a = _w("col_a.gd", 'const B = preload("%s")\n' % b)

	var graph = _scan([a])
	var pos = Layout.compute(graph, _sizes(graph))

	_check("columns: three placed", pos.size(), 3)
	_check("columns: a before b", pos[a].x < pos[b].x, true)
	_check("columns: b before c", pos[b].x < pos[c].x, true)
	# one column per distinct depth, and every node in a column shares an x
	_check("columns: distinct x count", _distinct_x(pos).size(), 3)


static func _test_roots_in_first_column() -> void:
	var shared = _w("r_shared.gd", "extends RefCounted\n")
	var a = _w("r_a.gd", 'const S = preload("%s")\n' % shared)
	var b = _w("r_b.gd", 'const S = preload("%s")\n' % shared)

	var graph = _scan([a, b])
	var pos = Layout.compute(graph, _sizes(graph))

	_check("roots: same column", pos[a].x, pos[b].x)
	_check("roots: leftmost", pos[a].x <= pos[shared].x, true)
	_check("roots: x is zero", pos[a].x, 0.0)


static func _test_no_overlap_in_column() -> void:
	var children:Array = []
	var lines:Array = []
	for i in 6:
		var child = _w("ov_child_%d.gd" % i, "extends RefCounted\n")
		children.append(child)
		lines.append('const C%d = preload("%s")' % [i, child])
	var root = _w("ov_root.gd", "\n".join(lines) + "\n")

	var graph = _scan([root])
	var sizes = _sizes(graph)
	var pos = Layout.compute(graph, sizes)

	var overlaps = 0
	for column in _columns(pos).values():
		column.sort_custom(func(p, q): return pos[p].y < pos[q].y)
		for i in column.size() - 1:
			var top:String = column[i]
			if pos[column[i + 1]].y < pos[top].y + sizes[top].y:
				overlaps += 1
	_check("overlap: none", overlaps, 0)
	_check("overlap: six children in one column", _columns(pos)[pos[children[0]].x].size(), 6)


static func _test_deterministic() -> void:
	var leaf = _w("det_leaf.gd", "extends RefCounted\n")
	var mid_a = _w("det_mid_a.gd", 'const L = preload("%s")\n' % leaf)
	var mid_b = _w("det_mid_b.gd", 'const L = preload("%s")\n' % leaf)
	var root = _w("det_root.gd", 'const A = preload("%s")\nconst B = preload("%s")\n' % [mid_a, mid_b])

	var graph = _scan([root])
	var sizes = _sizes(graph)
	_check("deterministic: identical output", Layout.compute(graph, sizes), Layout.compute(graph, sizes))


static func _test_sizes_respected() -> void:
	var tall = _w("sz_tall.gd", "extends RefCounted\n")
	var short = _w("sz_short.gd", "extends RefCounted\n")
	var root = _w("sz_root.gd", 'const T = preload("%s")\nconst S = preload("%s")\n' % [tall, short])

	var graph = _scan([root])
	var sizes = _sizes(graph)
	sizes[tall] = Vector2(200, 300)

	var pos = Layout.compute(graph, sizes, {"v_gap": 10.0})
	var gap = absf(pos[tall].y - pos[short].y)
	# whichever lands on top, the taller node's height has to be cleared
	var expected = (300.0 if pos[tall].y < pos[short].y else NODE_SIZE.y) + 10.0
	_check("sizes: spacing follows height", gap, expected)


static func _test_diamond_child_between_parents() -> void:
	var shared = _w("dia_shared.gd", "extends RefCounted\n")
	var left = _w("dia_left.gd", 'const S = preload("%s")\n' % shared)
	var right = _w("dia_right.gd", 'const S = preload("%s")\n' % shared)
	var root = _w("dia_root.gd", 'const L = preload("%s")\nconst R = preload("%s")\n' % [left, right])

	var graph = _scan([root])
	var pos = Layout.compute(graph, _sizes(graph))

	var top = minf(pos[left].y, pos[right].y)
	var bottom = maxf(pos[left].y, pos[right].y)
	_check("diamond: shared below top parent", pos[shared].y >= top, true)
	_check("diamond: shared above bottom parent", pos[shared].y <= bottom, true)


## The whole point of the barycentre pass. Alphabetical order puts these two edges across
## each other; ordering by parent position untangles them.
static func _test_barycentre_reduces_crossings() -> void:
	var z = _w("x_z.gd", "extends RefCounted\n")
	var y = _w("x_y.gd", "extends RefCounted\n")
	var a = _w("x_a.gd", 'const Z = preload("%s")\n' % z)
	var b = _w("x_b.gd", 'const Y = preload("%s")\n' % y)

	var graph = _scan([a, b])
	var sizes = _sizes(graph)

	var naive = Layout.compute(graph, sizes, {"sweeps": 0})
	var sorted = Layout.compute(graph, sizes)

	_check("crossings: naive order crosses", Layout.count_crossings(graph, naive), 1)
	_check("crossings: barycentre untangles", Layout.count_crossings(graph, sorted), 0)


## The point of max-depth layering: a node reached both directly and via a longer chain sits
## past the end of the chain, so every drawn edge moves strictly right.
static func _test_max_depth_pushes_shortcut_node_right() -> void:
	var shared = _w("md_shared.gd", "extends RefCounted\n")
	var mid = _w("md_mid.gd", 'const S = preload("%s")\n' % shared)
	var root = _w("md_root.gd", 'const M = preload("%s")\nconst S = preload("%s")\n' % [mid, shared])

	var graph = _scan([root])
	var pos = Layout.compute(graph, _sizes(graph))

	_check("max depth: shared pushed past the chain", pos[mid].x < pos[shared].x, true)
	_check("max depth: three distinct columns", _distinct_x(pos).size(), 3)

	var all_right = true
	for path:String in graph.nodes:
		for edge in graph.nodes[path].out_edges:
			if pos.has(edge.to) and pos[edge.to].x <= pos[path].x:
				all_right = false
	_check("max depth: every edge moves right", all_right, true)


## Longest path is undefined on a cycle, so a mutual preload collapses into one column.
static func _test_max_depth_cycle_shares_column() -> void:
	var a = _w("cy_a.gd", "extends RefCounted\n")
	var b = _w("cy_b.gd", 'const A = preload("%s")\n' % a)
	a = _w("cy_a.gd", 'const B = preload("%s")\n' % b) # close the cycle
	var root = _w("cy_root.gd", 'const A = preload("%s")\n' % a)

	var graph = _scan([root])
	var pos = Layout.compute(graph, _sizes(graph))

	_check("cycle: a and b share a column", pos[a].x, pos[b].x)
	_check("cycle: root stays left of the cycle", pos[root].x < pos[a].x, true)


## The scanner's shortest-hop depth is still available for comparison.
static func _test_max_depth_opt_min_keeps_old_columns() -> void:
	var shared = _w("mn_shared.gd", "extends RefCounted\n")
	var mid = _w("mn_mid.gd", 'const S = preload("%s")\n' % shared)
	var root = _w("mn_root.gd", 'const M = preload("%s")\nconst S = preload("%s")\n' % [mid, shared])

	var graph = _scan([root])
	var pos = Layout.compute(graph, _sizes(graph), {"depth_mode": "min"})

	_check("min depth: shared sits shallow", pos[shared].x, pos[mid].x)
	_check("min depth: two distinct columns", _distinct_x(pos).size(), 2)


## Depth 1 around b in a chain a→b→c→d is {a, b, c}: direct connections only, both ways.
static func _test_neighborhood_dist_limits_depth() -> void:
	var d = _w("nb_d.gd", "extends RefCounted\n")
	var c = _w("nb_c.gd", 'const D = preload("%s")\n' % d)
	var b = _w("nb_b.gd", 'const C = preload("%s")\n' % c)
	var a = _w("nb_a.gd", 'const B = preload("%s")\n' % b)

	var graph = _scan([a])
	var dist = Layout.neighborhood_dist(graph, [b], 1)

	_check("nb: depth 1 keeps three nodes", dist.size(), 3)
	_check("nb: focus at zero", dist.get(b), 0)
	_check("nb: dependent signed negative", dist.get(a), -1)
	_check("nb: dependency signed positive", dist.get(c), 1)
	_check("nb: two hops out excluded", dist.has(d), false)


## Dependents lay out left of the focus, dependencies right.
static func _test_neighborhood_columns_around_focus() -> void:
	var d = _w("nc_d.gd", "extends RefCounted\n")
	var c = _w("nc_c.gd", 'const D = preload("%s")\n' % d)
	var b = _w("nc_b.gd", 'const C = preload("%s")\n' % c)
	var a = _w("nc_a.gd", 'const B = preload("%s")\n' % b)

	var graph = _scan([a])
	var pos = Layout.compute_neighborhood(graph, [b], 1, _sizes(graph))

	_check("nb cols: three placed", pos.size(), 3)
	_check("nb cols: dependent left of focus", pos[a].x < pos[b].x, true)
	_check("nb cols: dependency right of focus", pos[c].x > pos[b].x, true)


## A node reached from both sides of the focus keeps the shorter side's sign.
static func _test_neighborhood_prefers_shorter_side() -> void:
	var f = _w("ns_f.gd", "extends RefCounted\n")
	var y = _w("ns_y.gd", 'const F = preload("%s")\n' % f)
	var x = _w("ns_x.gd", 'const Y = preload("%s")\n' % y)
	f = _w("ns_f.gd", 'const X = preload("%s")\n' % x) # f→x→y, and y→f closes the loop

	var graph = _scan([f])
	# y is 2 hops out on the dependency side but 1 hop out on the dependent side
	var dist = Layout.neighborhood_dist(graph, [f], 2)

	_check("nb tie: shorter side wins", dist.get(y), -1)
	_check("nb tie: x stays on the right", dist.get(x), 1)


## A node gets one row per kind on EITHER side - both ports of a row share the kind's colour,
## which is what stops GraphEdit gradienting every connection out to grey.
static func _test_estimate_size_tracks_kinds() -> void:
	var target = _w("es_target.gd", "extends RefCounted\n")
	var one_kind = _w("es_one.gd", 'const T = preload("%s")\n' % target)
	var two_kinds = _w("es_two.gd", 'const T = preload("%s")\nfunc a(): return load("%s")\n' % [target, target])

	var graph = _scan([one_kind, two_kinds])

	_check("rows: one outgoing kind", DepFileNode.row_kinds(graph.nodes[one_kind]).size(), 1)
	_check("rows: two outgoing kinds", DepFileNode.row_kinds(graph.nodes[two_kinds]).size(), 2)
	# the leaf references nothing, but is referenced two different ways - one row each
	_check("rows: incoming kinds count too", DepFileNode.row_kinds(graph.nodes[target]).size(), 2)
	_check("rows: enum order", DepFileNode.row_kinds(graph.nodes[target]), [Scanner.Kind.PRELOAD, Scanner.Kind.LOAD])

	var one = DepFileNode.estimate_size(graph.nodes[one_kind])
	var two = DepFileNode.estimate_size(graph.nodes[two_kinds])
	_check("estimate: two kinds is taller", two.y > one.y, true)
	_check("estimate: width constant", one.x, two.x)


## Folder mode draws the directory tree read left to right: a folder's column is its depth in
## that tree, and the vertical axis is reserved for siblings.
static func _test_folder_tree_shape() -> void:
	var b1 = _w("beta/b1.gd", "extends RefCounted\n")
	var b2 = _w("beta/b2.gd", "extends RefCounted\n")
	var a2 = _w("alpha/a2.gd", 'const B = preload("%s")\n' % b1)
	var a1 = _w("alpha/a1.gd", 'const A = preload("%s")\nconst B = preload("%s")\n' % [a2, b2])

	var graph = _scan([a1])
	var result = Layout.compute_by_folder(graph, _sizes(graph))
	var pos:Dictionary = result.positions
	var folders:Dictionary = result.folders
	var parent_dir = DIR.trim_suffix("/")
	var alpha = parent_dir + "/alpha"
	var beta = parent_dir + "/beta"

	_check("tree: all four placed", pos.size(), 4)
	_check("tree: the branch level gets a frame too", folders.size(), 3)
	_check("tree: parent starts the first column", folders[parent_dir].position.x, 0.0)
	_check("tree: children one column right", folders[alpha].position.x > 0.0, true)
	_check("tree: siblings share a column", folders[alpha].position.x, folders[beta].position.x)
	_check("tree: siblings stacked apart", folders[alpha].intersects(folders[beta]), false)
	# the scheme root carries no segment of its own, so it never reaches a title
	_check("tree: parent title", result.titles[parent_dir], "alib_dep_graph_tests")
	_check("tree: child title", result.titles[alpha], "alpha")
	# a file sits in its own folder's frame and no other
	_check("tree: a1 inside alpha", folders[alpha].encloses(Rect2(pos[a1], NODE_SIZE)), true)
	_check("tree: b1 inside beta", folders[beta].encloses(Rect2(pos[b1], NODE_SIZE)), true)
	_check("tree: a1 not inside beta", folders[beta].intersects(Rect2(pos[a1], NODE_SIZE)), false)
	_check("tree: a1 and a2 share a folder", result.dirs[a1], result.dirs[a2])
	_check("tree: no rects overlap", _overlapping_rects(folders), 0)


## A level with no files of its own and one way down is a corridor: it merges into its child
## and contributes a segment to the title instead of a whole column.
static func _test_folder_corridor_collapse() -> void:
	var leaf = _w("chain/a/b/c/leaf.gd", "extends RefCounted\n")
	var top = _w("chain/top.gd", 'const L = preload("%s")\n' % leaf)

	var graph = _scan([top])
	var result = Layout.compute_by_folder(graph, _sizes(graph))
	var folders:Dictionary = result.folders
	var chain = DIR + "chain"
	var deep = DIR + "chain/a/b/c"

	_check("collapse: three empty levels become none", folders.size(), 2)
	_check("collapse: a and b get no frame", folders.has(DIR + "chain/a"), false)
	_check("collapse: title joins the collapsed segments", result.titles[deep], "a/b/c")
	_check("collapse: root title picks up its own corridor", result.titles[chain], "alib_dep_graph_tests/chain")
	_check("collapse: still one column right", folders[deep].position.x > folders[chain].position.x, true)
	_check("collapse: leaf lands in the collapsed frame", result.dirs[leaf], deep)
	_check("collapse: frame encloses it", folders[deep].encloses(Rect2(result.positions[leaf], NODE_SIZE)), true)
	_check("collapse: top stays behind", result.dirs[top], chain)


static func _test_folder_column_wrap() -> void:
	var lines:Array = []
	for i in 10:
		var child = _w("big/w%d.gd" % i, "extends RefCounted\n")
		lines.append('const C%d = preload("%s")' % [i, child])
	var root = _w("big/w_root.gd", "\n".join(lines) + "\n")

	var graph = _scan([root])
	var sizes = _sizes(graph)
	# a cap low enough to force the folder into more than one sub-column
	var result = Layout.compute_by_folder(graph, sizes, {"max_column_height": 300.0})
	var pos:Dictionary = result.positions

	var xs = {}
	for path in pos:
		xs[pos[path].x] = true
	_check("wrap: folder split into sub-columns", xs.size() > 1, true)

	var overlaps = 0
	for x in xs:
		var column:Array = []
		for path in pos:
			if pos[path].x == x:
				column.append(path)
		column.sort_custom(func(p, q): return pos[p].y < pos[q].y)
		for i in column.size() - 1:
			if pos[column[i + 1]].y < pos[column[i]].y + sizes[column[i]].y:
				overlaps += 1
	_check("wrap: no overlap after wrapping", overlaps, 0)
	# every level above "big" is a corridor, so the whole chain is one frame
	_check("wrap: still one folder", result.folders.size(), 1)
	_check("wrap: folder title", result.titles.values()[0], "alib_dep_graph_tests/big")


# --- harness -----------------------------------------------------------------------------


static func _overlapping_rects(folders:Dictionary) -> int:
	var rects:Array = folders.values()
	var overlaps = 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				overlaps += 1
	return overlaps

## Global-class resolution off so a real project class_name cannot appear in these graphs.
static func _scan(roots:Array):
	var d = Scanner.open_many(roots)
	d.use_project_classes = false
	return d.get_graph()


static func _sizes(graph) -> Dictionary:
	var sizes = {}
	for path:String in graph.nodes:
		sizes[path] = NODE_SIZE
	return sizes


static func _distinct_x(pos:Dictionary) -> Array:
	var seen = {}
	for path in pos:
		seen[pos[path].x] = true
	return seen.keys()


static func _columns(pos:Dictionary) -> Dictionary:
	var columns = {}
	for path in pos:
		var x = pos[path].x
		if not columns.has(x):
			columns[x] = []
		columns[x].append(path)
	return columns


static func _w(rel_path:String, text:String) -> String:
	var path = DIR + rel_path
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("could not write fixture: " + path)
		return path
	file.store_string(text)
	file.close()
	return path


static func _reset_dir() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		_rm_recursive(DIR)
	DirAccess.make_dir_recursive_absolute(DIR)


static func _rm_recursive(dir:String) -> void:
	var da = DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for d in da.get_directories():
		_rm_recursive(dir.path_join(d) + "/")
	DirAccess.remove_absolute(dir)


static func _check(label:String, actual, expected) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failures.append("%s\n          expected: %s\n          actual:   %s" % [label, expected, actual])
