@tool
extends EditorScript

## Tests for DepMap.Scanner — the recursive resource-dependency collector.
##
## Fixtures are written to user:// at run time rather than living under res://. Two reasons:
## the scanner's whole job is reading text, so a fixture is far more readable sitting next to
## the assertion that reads it; and the dangling-uid case cannot exist as a res:// script at
## all — `preload("uid://<dead>")` is a compile error, so the project would refuse to import it.
##
## The diamond test is the one that matters most: it is the case the old plugin_exporter
## dictionary silently lost, keeping only the last file to reference a shared dependency.
##
##     load("res://addons/_lib/dep_map/_export_ignore/test/scanner_test.gd").run_tests()

const Scanner = preload("uid://dbn0kmkxa7caq") #! resolve DepMap.Scanner
const Kind = Scanner.Kind

const DIR = "user://alib_dep_tests/"
## A real uid from _lib, so uid resolution is tested against the live registry.
const UFILE_UID = "uid://bqfy5cvhth0m1"
const UFILE_PATH = "res://addons/_lib/util_r/src/file/u_file.gd"
const DEAD_UID = "uid://baaaaaaaaaaaa"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_reset_dir()

	_test_linear_chain()
	_test_diamond_keeps_every_reference()
	_test_cycle_terminates()
	_test_quote_and_line_shapes()
	_test_masked_preloads_ignored()
	_test_uid_and_relative()
	_test_dead_uid_unresolved()
	_test_load_calls()
	_test_extends()
	_test_global_classes()
	_test_serialized_files()
	_test_tres_script_class()
	_test_tags()
	_test_ignore_line_tags()
	_test_max_depth()
	_test_ignores_and_stop_at()
	_test_leaf_and_missing()
	_test_graph_helpers()
	_test_tree_parents()
	_test_filtered_parents_and_reachability()
	_test_access_path_resolution()
	_test_access_path_shapes()
	_test_resolution_never_loses_a_dependency()
	_test_namespace_hub_marking()

	_reset_dir()

	var output:Array[String] = []
	output.append("scanner: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	var res = run_tests()
	print("\n".join(res.output))


# --- cases -------------------------------------------------------------------------------

static func _test_ignore_line_tags() -> void:
	var leaf = _w("ignore_leaf.gd", "extends RefCounted\n")
	var child = _w("ignore_child.gd", 'const Leaf = preload("%s")\n' % leaf)
	var ignored = _w("ignore_root.gd", 'const Child = preload("%s") #! skip-ref\n' % child)
	var scanner = Scanner.open(ignored)
	scanner.use_project_classes = false
	_check("ignore: inert by default", scanner.get_graph().has(leaf), true)
	scanner.ignore_line_tags = ["skip-ref"]
	_check("ignore: suppresses edge and descendants", scanner.get_graph().nodes.size(), 1)

	for code in [
		'const Child = preload("%s") #! skip-ref',
		'extends "%s" #! skip-ref',
		'var child = load("%s") #! skip-ref',
	]:
		scanner.roots = [_w("ignore_shapes.gd", code % child + "\n")]
		_check("ignore: reference kind " + code, scanner.get_graph().has(child), false)

	for suffix in [" #! skip-reference", ' # prose mentions #! skip-ref', ' # "quoted #! skip-ref"']:
		scanner.roots = [_w("ignore_prose.gd", 'const Child = preload("%s")%s\n' % [child, suffix])]
		_check("ignore: exact comment tag " + suffix, scanner.get_graph().has(child), true)
	scanner.roots = [_w("ignore_header.gd", '#! skip-ref\nconst Child = preload("%s")\n' % child)]
	_check("ignore: header has no file scope", scanner.get_graph().has(leaf), true)

	scanner.class_map = {"Child": child}
	for code in [
		"var ignored = Child #! skip-ref\nvar included = Child\n",
		"var included = Child\nvar ignored = Child #! skip-ref\n",
		"extends Child #! skip-ref\nvar included = Child\n",
		"var ignored = Child.Leaf #! skip-ref\nvar included = Child.Leaf\n",
	]:
		scanner.roots = [_w("ignore_repeat.gd", code)]
		var graph = scanner.get_graph()
		_check("ignore: later/earlier use still gathers " + code, graph.has(leaf), true)
		for edge in graph.get_out_edges(scanner.roots[0]):
			var line:String = code.split("\n")[edge.line_no - 1]
			_check("ignore: no ignored occurrence emitted", line.contains("#! skip-ref"), false)

	scanner.roots = [_w("ignore_class.gd", "var child = Child.Leaf #! skip-ref\n")]
	_check("ignore: class and access path suppressed", scanner.get_graph().nodes.size(), 1)
	scanner.roots = [_w("ignore_declared.gd", "class_name Child #! skip-ref\nvar child: Child\n")]
	_check("ignore: declaration is still local", scanner.get_graph().nodes.size(), 1)

	var text = "var text = \"\"\"\n#! skip-ref\n\"\"\"\nvar real = Child #! skip-ref\n"
	_check("ignore: multiline string is not a tag",
		Scanner.ScanGD.ignored_line_numbers(text, ["skip-ref"]), {3: true})
	_check("ignore: masking preserves positions",
		Scanner.ScanGD.mask_ignored_lines(text, ["skip-ref"]).length(), text.length())
	_check("ignore: quoted tag is not a comment",
		Scanner.ScanGD.ignored_line_numbers('var text = "#! skip-ref"', ["skip-ref"]), {})


static func _test_linear_chain() -> void:
	var c = _w("chain_c.gd", "extends RefCounted\n")
	var b = _w("chain_b.gd", 'const C = preload("%s")\n' % c)
	var a = _w("chain_a.gd", 'const B = preload("%s")\n' % b)

	var graph = _scan(a)
	_check("chain: node count", graph.nodes.size(), 3)
	_check("chain: depth a", graph.nodes[a].depth, 0)
	_check("chain: depth b", graph.nodes[b].depth, 1)
	_check("chain: depth c", graph.nodes[c].depth, 2)
	_check("chain: a is root", graph.nodes[a].is_root, true)
	_check("chain: c dependents", graph.get_dependents(c), PackedStringArray([b]))
	_check("chain: path to c", graph.get_path_to(c), PackedStringArray([a, b, c]))


## Three files preloading one shared script must yield three edges into it. The legacy
## {dep: {dependent: x}} map kept one.
static func _test_diamond_keeps_every_reference() -> void:
	var shared = _w("dia_shared.gd", "extends RefCounted\n")
	var left = _w("dia_left.gd", 'const S = preload("%s")\n' % shared)
	var right = _w("dia_right.gd", 'const S = preload("%s")\n' % shared)
	var root = _w("dia_root.gd", 'const L = preload("%s")\nconst R = preload("%s")\nconst S = preload("%s")\n' % [left, right, shared])

	var graph = _scan(root)
	_check("diamond: node count", graph.nodes.size(), 4)
	_check("diamond: in_edges", graph.get_in_edges(shared).size(), 3)
	var dependents = Array(graph.get_dependents(shared))
	dependents.sort()
	_check("diamond: dependents", dependents, [left, right, root].duplicate())
	_check("diamond: shared depth is shortest", graph.nodes[shared].depth, 1)
	# only one node per file no matter how many edges reach it
	_check("diamond: shared scanned once", graph.nodes[shared].scanned, true)


static func _test_cycle_terminates() -> void:
	var a = DIR + "cyc_a.gd"
	var b = DIR + "cyc_b.gd"
	_w("cyc_a.gd", 'const B = preload("%s")\n' % b)
	_w("cyc_b.gd", 'const A = preload("%s")\n' % a)

	var graph = _scan(a)
	_check("cycle: node count", graph.nodes.size(), 2)
	_check("cycle: a in_edges", graph.get_in_edges(a).size(), 1)
	_check("cycle: b scanned", graph.nodes[b].scanned, true)


## The old parser gated on `line.count('"') == 2`, so a single-quoted preload or any second
## string literal on the line made the dependency vanish.
static func _test_quote_and_line_shapes() -> void:
	var t = _w("q_target.gd", "extends RefCounted\n")
	var src = _w("q_src.gd", "\n".join([
		"const A = preload('%s')" % t,                       # single quotes
		'const B = preload("%s") # trailing "comment string"' % t,
		'var msg = "hello" ; var C = preload("%s")' % t,     # second literal on the line
		'const D = preload("%s")' % t,
	]) + "\n")

	var graph = _scan(src)
	var edges = graph.get_in_edges(t)
	_check("quotes: four preload edges", edges.size(), 4)
	_check("quotes: line numbers", _line_nos(edges), [1, 2, 3, 4])
	_check("quotes: kinds", edges[0].kind, Kind.PRELOAD)
	_check("quotes: raw preserved", edges[0].raw, t)


static func _test_masked_preloads_ignored() -> void:
	var t = _w("m_target.gd", "extends RefCounted\n")
	var src = _w("m_src.gd", "\n".join([
		'# const A = preload("%s")' % t,
		'var s = "preload(\\"%s\\")"' % t,
		'const REAL = preload("%s")' % t,
	]) + "\n")

	var graph = _scan(src)
	_check("masked: only the real preload", graph.get_in_edges(t).size(), 1)
	_check("masked: line 3", graph.get_in_edges(t)[0].line_no, 3)


static func _test_uid_and_relative() -> void:
	var sub_dir = DIR + "sub/"
	DirAccess.make_dir_recursive_absolute(sub_dir)
	var nested = _w("sub/nested.gd", "extends RefCounted\n")
	var src = _w("rel_src.gd", "\n".join([
		'const U = preload("%s")' % UFILE_UID,
		'const N = preload("./sub/nested.gd")',
	]) + "\n")

	var d = _open(src)
	d.follow_extensions = ["gd"]
	d.max_depth = 1 # do not crawl all of _lib
	var graph = d.get_graph()

	_check("uid: resolved to path", graph.has(UFILE_PATH), true)
	_check("uid: raw kept as written", graph.get_in_edges(UFILE_PATH)[0].raw, UFILE_UID)
	_check("relative: resolved", graph.has(nested), true)
	_check("relative: no unresolved", graph.unresolved.size(), 0)


## A dead uid used to resolve to "" and land in the dependency map as an empty key.
static func _test_dead_uid_unresolved() -> void:
	var src = _w("dead_src.gd", 'const X = preload("%s")\n' % DEAD_UID)

	var graph = _scan(src)
	_check("dead uid: one unresolved", graph.unresolved.size(), 1)
	_check("dead uid: raw kept", graph.unresolved[0].raw, DEAD_UID)
	_check("dead uid: no empty node", graph.has(""), false)
	_check("dead uid: only the root node", graph.nodes.size(), 1)


static func _test_load_calls() -> void:
	var deep = _w("l_deep.gd", "extends RefCounted\n")
	var t = _w("l_target.gd", 'const D = preload("%s")\n' % deep)
	var src = _w("l_src.gd", "\n".join([
		'func a(): return load("%s")' % t,
		'func b(): return ResourceLoader.load("%s")' % t,
		'func c(): return preload("%s")' % t,
	]) + "\n")

	var graph = _scan(src)
	_check("load: two load edges", graph.get_edges_of_kind(Kind.LOAD).size(), 2)
	_check("load: one preload edge", graph.get_edges_of_kind(Kind.PRELOAD).size(), 2)
	_check("load: target reached", graph.has(t), true)

	# a load-only reference records the edge but does not drag in the subtree behind it
	var only_load = _w("l_only.gd", 'func a(): return load("%s")\n' % t)
	var d = _open(only_load)
	d.follow_load = false
	var g2 = d.get_graph()
	_check("follow_load off: edge kept", g2.has(t), true)
	_check("follow_load off: not scanned", g2.nodes[t].scanned, false)
	_check("follow_load off: subtree skipped", g2.has(deep), false)


static func _test_extends() -> void:
	var base = _w("e_base.gd", "extends RefCounted\n")
	var by_path = _w("e_path.gd", 'extends "%s"\n' % base)
	var cls_script = _w("e_class_script.gd", "extends RefCounted\n")
	var by_class = _w("e_class.gd", "extends FakeBase\n")

	var graph = _scan(by_path)
	_check("extends path: edge kind", graph.get_in_edges(base)[0].kind, Kind.EXTENDS_PATH)

	var d = _open(by_class)
	d.class_map = {"FakeBase": cls_script}
	var g2 = d.get_graph()
	_check("extends class: resolved", g2.has(cls_script), true)
	# not also a GLOBAL_CLASS edge for the same identifier
	_check("extends class: one edge", g2.get_in_edges(cls_script).size(), 1)
	_check("extends class: edge kind", g2.get_in_edges(cls_script)[0].kind, Kind.EXTENDS_CLASS)


static func _test_global_classes() -> void:
	var thing = _w("gc_thing.gd", "extends RefCounted\n")
	var other = _w("gc_other.gd", "extends RefCounted\n")
	var src = _w("gc_src.gd", "\n".join([
		"class_name GcSelf",
		"# FakeThing in a comment",
		'var s = "FakeThing in a string"',
		"func a(): return FakeThing.new()",
		"func b(): return FakeThing.other()", # second use, same class
		"func c(): return GcSelf.new()",      # self reference, not a dependency
		"func d(): return FakeOther.new()",
	]) + "\n")

	var d = _open(src)
	d.class_map = {"FakeThing": thing, "FakeOther": other, "GcSelf": src}
	var graph = d.get_graph()

	_check("globals: thing reached", graph.has(thing), true)
	_check("globals: deduped to one edge", graph.get_in_edges(thing).size(), 1)
	_check("globals: first use line", graph.get_in_edges(thing)[0].line_no, 4)
	_check("globals: kind", graph.get_in_edges(thing)[0].kind, Kind.GLOBAL_CLASS)
	_check("globals: no self edge", graph.nodes.size(), 3)
	_check("globals: recorded", graph.global_classes.get("FakeThing", {}).get("path", ""), thing)


static func _test_serialized_files() -> void:
	var script = _w("s_script.gd", "extends Node\n")
	var leaf = _w("s_leaf.gd", "extends RefCounted\n")
	# the script the scene points at has its own dependency, so recursion through .tscn is covered
	_w("s_script.gd", 'extends Node\nconst L = preload("%s")\n' % leaf)
	var scene = _w("s_scene.tscn", "\n".join([
		'[gd_scene load_steps=2 format=3 uid="uid://bscene000000"]',
		'',
		'[ext_resource type="Script" uid="%s" path="%s" id="1_abc"]' % [UFILE_UID, "res://stale/path.gd"],
		'[ext_resource type="Script" path="%s" id="2_def"]' % script,
		'',
		'[node name="Root" type="Node"]',
		'script = ExtResource("2_def")',
	]) + "\n")

	var d = _open(scene)
	d.max_depth = 2 # uid entry lands on u_file.gd; do not crawl _lib from here
	var graph = d.get_graph()

	_check("tscn: script reached", graph.has(script), true)
	_check("tscn: recursed into script", graph.has(leaf), true)
	_check("tscn: uid wins over stale path", graph.has(UFILE_PATH), true)
	_check("tscn: stale path not used", graph.has("res://stale/path.gd"), false)
	_check("tscn: edge kind", graph.get_in_edges(script)[0].kind, Kind.EXT_RESOURCE)
	# `id="` must not be read out of `uid="`
	_check("tscn: id attribute", graph.get_in_edges(UFILE_PATH)[0].meta.get("id", ""), "1_abc")


## The legacy parser recorded the .tres path here instead of the script's.
static func _test_tres_script_class() -> void:
	var script = _w("t_script.gd", "extends Resource\n")
	var res = _w("t_res.tres", "\n".join([
		'[gd_resource type="Resource" script_class="FakeRes" load_steps=2 format=3 uid="uid://bres00000000"]',
		'',
		'[resource]',
	]) + "\n")

	var d = _open(res)
	d.class_map = {"FakeRes": script}
	var graph = d.get_graph()

	_check("tres: script path not tres path", graph.has(script), true)
	_check("tres: edge kind", graph.get_in_edges(script)[0].kind, Kind.SCRIPT_CLASS)


## The library ships no handlers of its own, so what is tested here is the mechanism: what a
## handler is handed, what it can do with its return value, and when it fires at all.
static func _test_tags() -> void:
	var asset = _w("tag_asset.gd", "extends RefCounted\n")
	var other = _w("tag_other.gd", "extends RefCounted\n")
	var ignored = _w("tag_ignored.gd", "extends RefCounted\n")
	var src = _w("tag_src.gd", "\n".join([
		'const A = preload("%s") #! mark keep' % asset,
		# prose about the tag must not fire it - the tag has to open the comment
		'## write it as `#! mark "%s"` to pull a file in' % ignored,
		'var s = "#! mark \\"%s\\""' % ignored,
	]) + "\n")

	var plain = _scan(src)
	_check("tags: inert without a handler", plain.get_edges_of_kind(Kind.TAG).size(), 0)
	_check("tags: preload still found", plain.get_edges_of_kind(Kind.PRELOAD).size(), 1)

	# what the handler receives, and what its returned dict becomes
	var seen:Array = []
	var d = _open(src)
	d.add_tag_handler("#! mark", func(ctx):
		seen.append(ctx)
		return {"dir": ctx.value})
	var graph = d.get_graph()
	var tag_edges = graph.get_edges_of_kind(Kind.TAG)
	_check("tags: prefix stripped on register", d.tag_handlers.keys(), ["mark"])
	_check("tags: one edge per path literal", tag_edges.size(), 1)
	_check("tags: handler called once", seen.size(), 1)
	_check("tags: ctx value is the text after the tag", seen[0].value, "keep")
	_check("tags: ctx raws are the line's path literals", seen[0].raws, [asset])
	_check("tags: ctx line_no", seen[0].line_no, 1)
	_check("tags: return lands in edge meta", tag_edges[0].meta.get("dir", ""), "keep")
	_check("tags: tag name on the edge", tag_edges[0].tag, "mark")
	_check("tags: prose does not fire", graph.has(ignored), false)

	# null emits nothing, and a "paths" key replaces the targets and leaves the metadata
	var none = _open(src)
	none.add_tag_handler("mark", func(_ctx): return null)
	_check("tags: null emits no edge", none.get_graph().get_edges_of_kind(Kind.TAG).size(), 0)

	var redirected = _open(src)
	redirected.add_tag_handler("mark", func(_ctx): return {"paths": [other], "dir": "x"})
	var r_edges = redirected.get_graph().get_edges_of_kind(Kind.TAG)
	_check("tags: paths override the targets", r_edges[0].to, other)
	_check("tags: paths stripped from meta", r_edges[0].meta, {"dir": "x"})


static func _test_max_depth() -> void:
	var c = _w("d_c.gd", "extends RefCounted\n")
	var b = _w("d_b.gd", 'const C = preload("%s")\n' % c)
	var a = _w("d_a.gd", 'const B = preload("%s")\n' % b)

	var d = _open(a)
	d.max_depth = 1
	var graph = d.get_graph()
	_check("max_depth: b reached", graph.has(b), true)
	_check("max_depth: c not reached", graph.has(c), false)
	_check("max_depth: b not scanned", graph.nodes[b].scanned, false)


static func _test_ignores_and_stop_at() -> void:
	DirAccess.make_dir_recursive_absolute(DIR + "skipme/")
	DirAccess.make_dir_recursive_absolute(DIR + "stopme/")
	var deep = _w("skipme/deep.gd", "extends RefCounted\n")
	var skipped = _w("skipme/skipped.gd", 'const D = preload("%s")\n' % deep)
	var stop_child = _w("stopme/child.gd", "extends RefCounted\n")
	var stopped = _w("stopme/stopped.gd", 'const C = preload("%s")\n' % stop_child)
	var plain = _w("i_plain.gd", "extends RefCounted\n")
	var src = _w("i_src.gd", "\n".join([
		'const A = preload("%s")' % skipped,
		'const B = preload("%s")' % stopped,
		'const C = preload("%s")' % plain,
	]) + "\n")

	var by_path = _open(src)
	by_path.ignore_dir_paths = [DIR + "skipme"]
	var g1 = by_path.get_graph()
	_check("ignore path: dropped", g1.has(skipped), false)
	_check("ignore path: sibling kept", g1.has(plain), true)

	var by_name = _open(src)
	by_name.ignore_dir_names = ["skipme"]
	var g2 = by_name.get_graph()
	_check("ignore name: dropped", g2.has(skipped), false)

	var stop = _open(src)
	stop.stop_at_dir_paths = [DIR + "stopme"]
	var g3 = stop.get_graph()
	_check("stop_at: edge kept", g3.has(stopped), true)
	_check("stop_at: not scanned", g3.nodes[stopped].scanned, false)
	_check("stop_at: child not reached", g3.has(stop_child), false)


static func _test_leaf_and_missing() -> void:
	var png = DIR + "asset.png"
	FileAccess.open(png, FileAccess.WRITE).store_string("not really a png")
	var missing = DIR + "not_here.gd"
	var src = _w("leaf_src.gd", "\n".join([
		'const IMG = preload("%s")' % png,
		'const GONE = preload("%s")' % missing,
	]) + "\n")

	var graph = _scan(src)
	_check("leaf: png recorded", graph.has(png), true)
	_check("leaf: png not scanned", graph.nodes[png].scanned, false)
	_check("leaf: png exists", graph.nodes[png].exists, true)
	_check("missing: recorded by default", graph.has(missing), true)
	_check("missing: exists false", graph.nodes[missing].exists, false)
	_check("missing: listed", graph.get_missing(), PackedStringArray([missing]))

	var strict = _open(src)
	strict.include_missing = false
	var g2 = strict.get_graph()
	_check("missing: dropped when excluded", g2.has(missing), false)


static func _test_graph_helpers() -> void:
	var c = _w("f_c.gd", "extends RefCounted\n")
	var b = _w("f_b.gd", 'const C = preload("%s")\n' % c)
	var a = _w("f_a.gd", 'const B = preload("%s")\n' % b)

	var graph = _scan(a)
	_check("helpers: get_paths excludes roots", graph.get_paths(false, false), PackedStringArray([b, c]))
	_check("helpers: get_paths includes roots", graph.get_paths(false, true).size(), 3)
	_check("helpers: dependencies of a", graph.get_dependencies(a), PackedStringArray([b]))
	_check("helpers: dependents of c", graph.get_dependents(c), PackedStringArray([b]))


## `extends Hub.Base` names base.gd. Resolving only the head lands on the namespace file,
## which preloads every sibling and is referred back to by them - one unresolved dotted path
## manufactures a hub, a fan-out and a cycle that are not in the code.
static func _test_access_path_resolution() -> void:
	var base = _w("ns_base.gd", "extends RefCounted\n")
	var other = _w("ns_other.gd", "extends RefCounted\n")
	var hub = _w("ns_hub.gd", '# This file is auto-generated. Do not edit.\n\nconst Base = preload("%s")\nconst Other = preload("%s")\n' % [base, other])
	var user = _w("ns_user.gd", 'extends Hub.Base\n')

	var d = _open(user)
	d.class_map = {"Hub": hub}
	var graph = d.get_graph()

	_check("access: reaches the real base", graph.has(base), true)
	_check("access: edge carries the expression", graph.get_in_edges(base)[0].meta.get("resolved_from", ""), "Hub.Base")
	_check("access: hub still reached", graph.has(hub), true)
	# the tree prefers the direct reference over the detour through the hub
	_check("access: tree parent is the user", graph.get_tree_parents()[base].from, user)

	# off, the same file resolves no further than the hub
	var plain = _open(user)
	plain.class_map = {"Hub": hub}
	plain.resolve_access_paths = false
	var g2 = plain.get_graph()
	_check("access: off keeps the hub edge", g2.has(hub), true)
	_check("access: off reaches base only via hub", g2.get_in_edges(base)[0].from, hub)


## Multi-segment walks, local-const heads, and stopping cleanly on an inner class.
static func _test_access_path_shapes() -> void:
	var leaf = _w("ap_leaf.gd", "extends RefCounted\n")
	var mid = _w("ap_mid.gd", 'const Leaf = preload("%s")\n' % leaf)
	var top = _w("ap_top.gd", 'const Mid = preload("%s")\n' % mid)

	# three segments, resolved through two files
	var deep = _w("ap_deep.gd", 'const T = preload("%s")\nvar x = T.Mid.Leaf\n' % top)
	var d = _open(deep)
	var graph = d.get_graph()
	_check("shapes: local-const head resolves", graph.has(leaf), true)
	var leaf_edge = null
	for edge in graph.get_in_edges(leaf):
		if edge.meta.has("resolved_from"):
			leaf_edge = edge
	_check("shapes: three segments walked", leaf_edge != null and leaf_edge.meta.resolved_from == "T.Mid.Leaf", true)
	# consumed names the segment that landed on the file: parts[consumed - 1] == "Leaf", no tail
	_check("shapes: consumed counts every segment", leaf_edge.meta.get("consumed", -1) if leaf_edge else -1, 3)

	# an inner class is not a const preload, so the walk stops at the last real file it saw
	var inner = _w("ap_inner.gd", 'const T = preload("%s")\nvar y = T.Mid.SomeInnerClass\n' % top)
	var g2 = _open(inner).get_graph()
	var partial = null
	for edge in g2.get_in_edges(mid):
		if edge.meta.get("partial", false):
			partial = edge
	_check("shapes: partial stops at the last real file", partial != null, true)
	_check("shapes: partial keeps the walked path", partial.meta.resolved_from if partial else "", "T.Mid.SomeInnerClass")
	# stopped after "Mid", so parts[1] names the file and "SomeInnerClass" is the unresolved tail
	_check("shapes: consumed marks where it stopped", partial.meta.get("consumed", -1) if partial else -1, 2)
	# leaf is still in the graph - the preload chain reaches it - but no RESOLVED edge points
	# there, which is the thing a partial walk must not fabricate
	var invented = 0
	for edge in g2.get_in_edges(leaf):
		if edge.meta.has("resolved_from"):
			invented += 1
	_check("shapes: partial invents nothing past it", invented, 0)

	# a partial that never got past its head adds nothing - that edge already exists
	var head_only = _w("ap_head_only.gd", 'const M = preload("%s")\nvar z = M.SomeInnerClass\n' % mid)
	var g3 = _open(head_only).get_graph()
	var redundant = 0
	for edge in g3.get_in_edges(mid):
		if edge.meta.has("resolved_from"):
			redundant += 1
	_check("shapes: no redundant head-only edge", redundant, 0)
	_check("shapes: head still reached by its preload", g3.has(mid), true)


## The plugin_exporter guarantee: resolution only ever ADDS. A file the collector reports
## with resolution off must still be reported with it on.
static func _test_resolution_never_loses_a_dependency() -> void:
	var base = _w("keep_base.gd", "extends RefCounted\n")
	var hub = _w("keep_hub.gd", '# This file is auto-generated. Do not edit.\n\nconst Base = preload("%s")\n' % base)
	var user = _w("keep_user.gd", 'extends Hub.Base\nvar v = Hub.Base\n')

	var off = _open(user)
	off.class_map = {"Hub": hub}
	off.resolve_access_paths = false
	var reached_off = off.get_graph().get_paths(false, false)

	var on = _open(user)
	on.class_map = {"Hub": hub}
	var graph_on = on.get_graph()
	var reached_on = graph_on.get_paths(false, false)

	var lost:Array = []
	for path in reached_off:
		if not graph_on.has(path):
			lost.append(path)
	_check("guarantee: nothing lost when resolving", lost, [])
	_check("guarantee: hub survives resolution", reached_on.has(hub), true)
	_check("guarantee: resolution adds the direct edge", reached_on.has(base), true)


static func _test_namespace_hub_marking() -> void:
	var base = _w("hm_base.gd", "extends RefCounted\n")
	var hub = _w("hm_hub.gd", '# This file is auto-generated. Do not edit.\n\nconst Base = preload("%s")\n' % base)
	var plain = _w("hm_plain.gd", 'const Base = preload("%s")\n' % base)
	var user = _w("hm_user.gd", 'const H = preload("%s")\nconst P = preload("%s")\n' % [hub, plain])

	var graph = _scan(user)
	var hub_edge = graph.get_in_edges(hub)[0]
	var plain_edge = graph.get_in_edges(plain)[0]
	_check("hub: generated file marked", hub_edge.meta.get("namespace_hub", false), true)
	_check("hub: ordinary file not marked", plain_edge.meta.get("namespace_hub", false), false)
	# the node carries it too, so a viewer can filter the file itself and not just its edges
	_check("hub: node flagged", graph.get_node_data(hub).is_namespace_hub, true)
	_check("hub: ordinary node not flagged", graph.get_node_data(plain).is_namespace_hub, false)
	_check("hub: root not flagged", graph.get_node_data(user).is_namespace_hub, false)


## The spanning tree the graph view reads as "why is this file here": one parent per node,
## chosen by shallowest source, so there are no cycles to draw.
static func _test_tree_parents() -> void:
	var shared = _w("tp_shared.gd", "extends RefCounted\n")
	var left = _w("tp_left.gd", 'const S = preload("%s")\n' % shared)
	var right = _w("tp_right.gd", 'const S = preload("%s")\n' % shared)
	var root = _w("tp_root.gd", 'const L = preload("%s")\nconst R = preload("%s")\nconst S = preload("%s")\n' % [left, right, shared])

	var graph = _scan(root)
	var parents = graph.get_tree_parents()

	_check("tree: root has no parent", parents.has(root), false)
	_check("tree: one entry per non-root", parents.size(), 3)
	# shared has three in_edges; the tree keeps only the shallowest source, which is the root
	_check("tree: shared has 3 in_edges", graph.get_in_edges(shared).size(), 3)
	_check("tree: shared parent is the root", parents[shared].from, root)
	_check("tree: left parent is the root", parents[left].from, root)
	_check("tree: deterministic", graph.get_tree_parents()[shared].from, parents[shared].from)
	_check("tree: agrees with get_path_to", graph.get_path_to(shared), PackedStringArray([root, shared]))

	# a cycle must still terminate with one parent each and no self-parenting
	var a = DIR + "tp_cyc_a.gd"
	var b = DIR + "tp_cyc_b.gd"
	_w("tp_cyc_a.gd", 'const B = preload("%s")\n' % b)
	_w("tp_cyc_b.gd", 'const A = preload("%s")\n' % a)
	var cyc = _scan(a)
	var cyc_parents = cyc.get_tree_parents()
	_check("tree: cycle root excluded", cyc_parents.has(a), false)
	_check("tree: cycle child parented", cyc_parents[b].from, a)


## A viewer draws only some of the edges. Both of these take its filter, so what it gets back
## is a parent it will actually draw - the alternative is a node with no incoming line at all.
static func _test_filtered_parents_and_reachability() -> void:
	var leaf = _w("fp_leaf.gd", "extends RefCounted\n")
	var only = _w("fp_only.gd", "extends RefCounted\n")
	var hub = _w("fp_hub.gd", '# This file is auto-generated. Do not edit.\n\nconst L = preload("%s")\nconst O = preload("%s")\n' % [leaf, only])
	var root = _w("fp_root.gd", 'const H = preload("%s")\nconst L = preload("%s")\n' % [hub, leaf])

	var graph = _scan(root)
	var no_hubs = func(edge): return not edge.meta.get("namespace_hub", false)

	# unfiltered, leaf takes the root as its parent anyway - the hub is deeper
	_check("filter: leaf parented by root", graph.get_tree_parents()[leaf].from, root)
	var parents = graph.get_tree_parents(no_hubs)
	_check("filter: hub loses its parent", parents.has(hub), false)
	_check("filter: leaf keeps a real parent", parents[leaf].from, root)
	_check("filter: no parent is a hub edge", parents.values().any(func(e): return e.meta.get("namespace_hub", false)), false)
	_check("filter: nothing survives an empty filter", graph.get_tree_parents(func(_e): return false).size(), 0)

	# and the reachability walk drops what only the hub was holding up
	var reachable = graph.get_reachable(no_hubs)
	_check("reach: root kept", reachable.has(root), true)
	_check("reach: leaf reached another way", reachable.has(leaf), true)
	_check("reach: hub dropped", reachable.has(hub), false)
	_check("reach: hub-only file dropped with it", reachable.has(only), false)
	_check("reach: unfiltered keeps everything", graph.get_reachable().size(), graph.nodes.size())
	_check("reach: empty filter leaves the roots", graph.get_reachable(func(_e): return false).size(), 1)


# --- harness -----------------------------------------------------------------------------

static func _scan(root:String):
	return _open(root).get_graph()


## Global-class resolution is on by default; tests that do not inject a map opt out so a real
## project class_name cannot leak into the assertions.
static func _open(root:String):
	var d = Scanner.open(root)
	d.use_project_classes = false
	return d


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


static func _line_nos(edges:Array) -> Array:
	var out = []
	for edge in edges:
		out.append(edge.line_no)
	return out


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
