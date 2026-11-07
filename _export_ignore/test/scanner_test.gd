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
	_test_alias_walk()
	_test_alias_edges()
	_test_inherited_heads()
	_test_pass_through()
	_test_self_reference()
	_test_literals()
	_test_preload_const()
	_test_first_occurrence_on_dropped_line()
	_test_keep_dirs()
	_test_tags_block_pass_through()

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


## A const that is itself an alias has to be crossed, read in the scope of the file declaring it.
static func _test_alias_walk() -> void:
	var leaf = _w("al_leaf.gd", "extends RefCounted\nclass Inner:\n\tconst V = 1\n")
	var utils = _w("al_utils.gd", 'const Leaf = preload("%s")\n' % leaf)
	var hub = _w("al_hub.gd", """const Utils = preload("%s")
const Leaf = Utils.Leaf
const Renamed = Utils.Leaf
const Inner = Utils.Leaf.Inner
const SLOT = EditorPlugin.DOCK_SLOT_NONE
const Typed: Script = preload("%s")
""" % [utils, leaf])
	var classes = {"Hub": hub}
	var result = func(expression:String): return Scanner.ResolveAccess.resolve(expression, {}, classes, {})

	var alias = result.call("Hub.Leaf")
	_check("alias: crossed to the file", alias.path, leaf)
	_check("alias: not partial", alias.partial, false)
	_check("alias: head stays the hub", alias.head_path, hub)
	_check("alias: every const recorded", alias.crossed.map(func(h): return h.name), ["Leaf", "Utils", "Leaf"])

	_check("alias: rename binds the real name", result.call("Hub.Renamed").bind_name, "Leaf")

	var inner = result.call("Hub.Inner.V")
	_check("alias: inner lands on its file", inner.path, leaf)
	_check("alias: inner is partial", inner.partial, true)
	_check("alias: suffix carries what the expression hides", inner.suffix, ["Inner"])
	_check("alias: binds the file, not the alias", inner.bind_name, "Leaf")
	_check("alias: expression tail stays unconsumed", inner.consumed, 2)

	_check("alias: engine class stops the walk", result.call("Hub.SLOT").consumed, 1)
	_check("alias: typed const walked", result.call("Hub.Typed").path, leaf)

	# hubs preload each other as a matter of course
	_w("cy_b.gd", "const X = preload(\"%s\").X\n" % (DIR + "cy_a.gd"))
	var cycle_a = _w("cy_a.gd", "const X = preload(\"%s\").X\n" % (DIR + "cy_b.gd"))
	var cycle = Scanner.ResolveAccess.resolve("A.X", {}, {"A": cycle_a}, {})
	_check("alias: a cycle terminates", cycle.path != "", true)

	var self_alias = _w("cy_self.gd", "const X = X.Y\n")
	_check("alias: self reference terminates", Scanner.ResolveAccess.resolve("S.X", {}, {"S": self_alias}, {}).consumed, 1)


## `preload("a.gd").Inner` names Inner, and reading it as a.gd would rewrite to the wrong class.
static func _test_alias_edges() -> void:
	var target = _w("sf_target.gd", "class Inner:\n\tconst V = 1\n")
	var hub = _w("sf_hub.gd", 'const Inner = preload("%s").Inner\nconst Called = preload("%s").new()\n' % [target, target])
	var paths = Scanner.ResolveAccess.get_const_paths(hub, {})
	_check("suffix: not reported as a plain preload", paths.has("Inner"), false)
	_check("suffix: call is not a const path", paths.has("Called"), false)
	var result = Scanner.ResolveAccess.resolve("Hub.Inner.V", {}, {"Hub": hub}, {})
	_check("suffix: walks to the inner class", result.suffix, ["Inner"])
	_check("suffix: binds the file", result.bind_name, "SfTarget")

	# a const reached through a file, not through a dotted head, still crosses what it crosses
	var mid = _w("sf_mid.gd", 'const Target = preload("%s")\n' % target)
	var user = _w("sf_user.gd", 'const T = preload("%s").Target\n' % mid)
	var crossed = []
	for edge in _scan(user).get_out_edges(user):
		crossed.append_array(edge.meta.get("crossed", []))
	_check("suffix: preload chain reports its crossing", crossed.any(func(h): return h.file == mid and h.name == "Target"), true)


## Inherited consts are heads too, and one still in use has to be visible from the derived file.
static func _test_inherited_heads() -> void:
	var leaf = _w("ih_leaf.gd", "extends RefCounted\n")
	var hub = _w("ih_hub.gd", 'const Leaf = preload("%s")\nstatic func f(): pass\n' % leaf)
	var base = _w("ih_base.gd", 'extends RefCounted\nconst H = preload("%s")\n' % hub)

	var dotted = _w("ih_dotted.gd", 'extends "%s"\nvar v = H.Leaf\n' % base)
	var d = _open(dotted)
	d.class_map = {}
	var edge = _edge_from(d.get_graph(), dotted, leaf)
	_check("inherit: head resolved through the base", edge != null, true)

	var bare = _w("ih_bare.gd", 'extends "%s"\nfunc g(): H.f()\n' % base)
	var kept = null
	for e in _open(bare).get_graph().get_out_edges(bare):
		if e.raw == "H":
			kept = e
	_check("inherit: bare use gets its own edge", kept.to if kept else "", hub)
	_check("inherit: crossing names the base", kept.meta.crossed[0].file if kept else "", base)


static func _test_pass_through() -> void:
	var leaf = _w("pt_leaf.gd", "extends RefCounted\n")
	var sibling = _w("pt_sibling.gd", "extends RefCounted\n")
	var hub = _w("pt_hub.gd", '# This file is auto-generated. Do not edit.\n\nconst Leaf = preload("%s")\nconst Sibling = preload("%s")\nstatic func f(): pass\n' % [leaf, sibling])
	var classes = {"Hub": hub}

	var user = _w("pt_user.gd", "extends RefCounted\nconst Leaf = Hub.Leaf\nvar v = Hub.Leaf\n")
	var marked = _open(user)
	marked.class_map = classes
	var graph = marked.get_graph()
	_check("pass: off keeps the hub", graph.has(hub), true)
	_check("pass: off marks the head", _edge_from(graph, user, hub).meta.get("pass_through", false), true)

	var collapsed = _open(user)
	collapsed.class_map = classes
	collapsed.collapse_pass_through = true
	var g2 = collapsed.get_graph()
	_check("pass: on drops the hub", g2.has(hub), false)
	_check("pass: on keeps the target", g2.has(leaf), true)
	_check("pass: on drops the sibling", g2.has(sibling), false)

	# one mention that is not a chain keeps the head
	var bare = _w("pt_bare.gd", "extends RefCounted\nconst Leaf = Hub.Leaf\nvar h = Hub\n")
	var d = _open(bare)
	d.class_map = classes
	d.collapse_pass_through = true
	_check("pass: bare mention keeps the head", d.get_graph().has(hub), true)
	var call = _w("pt_call.gd", "extends RefCounted\nconst Leaf = Hub.Leaf\nfunc g(): Hub.f()\n")
	var d2 = _open(call)
	d2.class_map = classes
	d2.collapse_pass_through = true
	_check("pass: method call keeps the head", d2.get_graph().has(hub), true)

	# strings and comments are not mentions
	var masked = _w("pt_masked.gd", 'extends RefCounted\nconst Leaf = Hub.Leaf\nvar s = "Hub" # Hub\n')
	var d3 = _open(masked)
	d3.class_map = classes
	d3.collapse_pass_through = true
	_check("pass: strings and comments do not count", d3.get_graph().has(hub), false)

	# a local hub is the same thing with a preload in front of it
	var local = _w("pt_local.gd", 'extends RefCounted\nconst H = preload("%s")\nconst Leaf = H.Leaf\n' % hub)
	var d4 = _open(local)
	d4.collapse_pass_through = true
	var g4 = d4.get_graph()
	_check("pass: local hub dropped", g4.has(hub), false)
	_check("pass: local target kept", g4.has(leaf), true)

	# freeing a declaration can free the head on its right
	var chain = _w("pt_chain.gd", 'extends RefCounted\nconst Lib = preload("%s")\nconst H = Lib.Hub\nconst Leaf = H.Leaf\n' % _w("pt_lib.gd", 'const Hub = preload("%s")\nstatic func f(): pass\n' % hub))
	var d5 = _open(chain)
	d5.collapse_pass_through = true
	var g5 = d5.get_graph()
	_check("pass: chained declarations all go", g5.has(hub), false)
	_check("pass: chained target kept", g5.has(leaf), true)


## A script naming its own type through its namespace mentions the head, so the walk back has to
## count, without a self-loop reaching the graph.
static func _test_self_reference() -> void:
	var path = DIR + "sr_self.gd"
	var hub = _w("sr_hub.gd", 'const Self = preload("%s")\n' % path)
	_w("sr_self.gd", "extends RefCounted\nstatic func make() -> Hub.Self:\n\treturn null\n")
	var d = _open(path)
	d.class_map = {"Hub": hub}
	d.collapse_pass_through = true
	var graph = d.get_graph()
	_check("self: head is a pass-through", graph.has(hub), false)
	_check("self: no self-loop", graph.get_out_edges(path).size(), 0)
	_check("self: recorded apart", graph.self_edges.get(path, []).size(), 1)


## `const MY_INT = GlobalClass.MY_INT`: the value is all the file needs, so the class is not a
## dependency and no edge points anywhere.
static func _test_literals() -> void:
	var cache = _w("lt_cache.gd", """const STATE = 3
const NAME = "a # b"
const SN = &"s"
const NEG = -1.5
const FLAG = true
const NONE = null
const TYPED:float = 1
const SUM = 1 + 2
""")
	var hub = _w("lt_hub.gd", 'const Cache = preload("%s")\nconst STATE = Cache.STATE\nstatic func f(): pass\n' % cache)
	var resolved = func(e:String): return Scanner.ResolveAccess.resolve(e, {}, {"Hub": hub, "Cache": cache}, {})

	_check("literal: int", resolved.call("Cache.STATE").literal, "3")
	_check("literal: string keeps its hash", resolved.call("Cache.NAME").literal, '"a # b"')
	_check("literal: string name", resolved.call("Cache.SN").literal, '&"s"')
	_check("literal: negative float", resolved.call("Cache.NEG").literal, "-1.5")
	_check("literal: bool", resolved.call("Cache.FLAG").literal, "true")
	_check("literal: null", resolved.call("Cache.NONE").literal, "null")
	_check("literal: through an alias", resolved.call("Hub.STATE").literal, "3")
	_check("literal: typed left alone", resolved.call("Cache.TYPED").literal, "")
	_check("literal: expression left alone", resolved.call("Cache.SUM").literal, "")

	var user = _w("lt_user.gd", "extends RefCounted\nconst MY_INT = Hub.STATE\n")
	var d = _open(user)
	d.class_map = {"Hub": hub}
	d.collapse_pass_through = true
	var graph = d.get_graph()
	_check("literal: class is no dependency", graph.has(hub), false)
	_check("literal: nor its file", graph.has(cache), false)
	_check("literal: recorded for the plan", graph.self_edges.get(user, []).size(), 1)

	# a tagged value is more than its value
	var tagged = _w("lt_tagged.gd", 'const NOTE = "res://x.txt" #! dep\n')
	var tag_user = _w("lt_tag_user.gd", "extends RefCounted\nconst N = Tagged.NOTE\n")
	var d2 = _open(tag_user)
	d2.class_map = {"Tagged": tagged}
	d2.collapse_pass_through = true
	d2.add_tag_handler("dep", func(_ctx): return {})
	var g2 = d2.get_graph()
	_check("literal: tagged value keeps its file", g2.has(tagged), true)
	_check("literal: tagged value is not inlined", g2.self_edges.get(tag_user, []).size(), 0)


## A preload of a const string is as required as one of a literal path.
static func _test_preload_const() -> void:
	var target = _w("pc_target.gd", "extends RefCounted\n")
	var user = _w("pc_user.gd", 'const T = preload(PATH)\nconst PATH = "%s"\n' % target)
	var edge = _edge_from(_scan(user), user, target)
	_check("preload const: resolved", edge != null, true)
	_check("preload const: a real preload", edge.kind if edge else -1, Kind.PRELOAD)


## An expression is recorded at its first occurrence, which may be a line that goes away.
static func _test_first_occurrence_on_dropped_line() -> void:
	var leaf = _w("fo_leaf.gd", "extends RefCounted\n")
	var sub = _w("fo_sub.gd", 'const Leaf = preload("%s")\n' % leaf)
	var hub = _w("fo_hub.gd", 'const Sub = preload("%s")\nstatic func f(): pass\n' % sub)
	var user = _w("fo_user.gd", 'const H = preload("%s")\nconst S = H.Sub\nconst Leaf = S.Leaf\nvar v = H.Sub\n' % hub)
	var d = _open(user)
	d.collapse_pass_through = true
	_check("first occurrence: target of a surviving use kept", d.get_graph().has(sub), true)

	# the same trap for a class: first mentioned on a line that goes, used bare further down
	var cls = _w("fo_class.gd", 'extends RefCounted\nconst Sub = Hub.Sub\nvar a:Hub\n')
	var d2 = _open(cls)
	d2.class_map = {"Hub": hub}
	d2.collapse_pass_through = true
	_check("first occurrence: bare class use keeps the head", d2.get_graph().has(hub), true)


static func _test_keep_dirs() -> void:
	var leaf = _w("kd_leaf.gd", "extends RefCounted\n")
	var hub = _w("keep/kd_hub.gd", 'const Leaf = preload("%s")\n' % leaf)
	var local = _w("kd_local.gd", 'extends RefCounted\nconst H = preload("%s")\nconst Leaf = H.Leaf\n' % hub)

	var d = _open(local)
	d.collapse_pass_through = true
	d.collapse_keep_dirs = [DIR + "keep"]
	var graph = d.get_graph()
	_check("keep: hub stays", graph.has(hub), true)
	_check("keep: local head not reducible", _edge_from(graph, local, leaf).meta.get("reducible", true), false)

	var global = _w("kd_global.gd", "extends RefCounted\nconst Leaf = Hub.Leaf\n")
	var d2 = _open(global)
	d2.class_map = {"Hub": hub}
	d2.collapse_pass_through = true
	d2.collapse_keep_dirs = [DIR + "keep"]
	var g2 = d2.get_graph()
	_check("keep: global head stays followed", g2.has(hub), true)
	_check("keep: global head still reducible", _edge_from(g2, global, leaf).meta.get("reducible", false), true)


## A skipped file is never scanned, so a tag inside it would quietly stop firing.
static func _test_tags_block_pass_through() -> void:
	var asset = _w("tg_asset.txt", "x")
	var leaf = _w("tg_leaf.gd", 'const A = "%s" #! dep\n' % asset)
	var plain_leaf = _w("tg_plain.gd", "extends RefCounted\n")
	var tagged_hub = _w("tg_hub.gd", 'const Leaf = preload("%s")\nconst A = "%s" #! dep\n' % [plain_leaf, asset])
	var clean_top = _w("tg_top.gd", 'const Mid = preload("%s")\n' % tagged_hub)
	var clean_hub = _w("tg_clean.gd", 'const Leaf = preload("%s")\n' % leaf)
	var tag = func(_ctx): return {}

	var make = func(root:String, classes:Dictionary):
		var d = _open(root)
		d.class_map = classes
		d.collapse_pass_through = true
		d.add_tag_handler("dep", tag)
		return d.get_graph()

	var user = _w("tg_user.gd", "extends RefCounted\nconst Leaf = Hub.Leaf\n")
	var graph = make.call(user, {"Hub": tagged_hub})
	_check("tag: tagged hub is not a pass-through", graph.has(tagged_hub), true)
	_check("tag: its tag still fires", graph.has(asset), true)

	var through = _w("tg_through.gd", "extends RefCounted\nconst Leaf = Top.Mid.Leaf\n")
	var g2 = make.call(through, {"Top": clean_top})
	_check("tag: tagged file mid-chain blocks", g2.has(tagged_hub), true)
	_check("tag: and its tag fires", g2.has(asset), true)

	var landing = _w("tg_landing.gd", "extends RefCounted\nconst Leaf = Hub.Leaf\n")
	var g3 = make.call(landing, {"Hub": clean_hub})
	_check("tag: landing on a tagged file still collapses", g3.has(clean_hub), false)
	_check("tag: the landing file's tag fires", g3.has(asset), true)

	var own = _w("tg_own.gd", 'extends RefCounted\nconst H = preload("%s") #! dep\nconst Leaf = H.Leaf\n' % clean_hub)
	var g4 = make.call(own, {})
	_check("tag: tagged const line is not a pass-through", g4.has(clean_hub), true)

	# a tag elsewhere in the walking file has no bearing on its heads
	var unrelated = _w("tg_unrelated.gd", 'extends RefCounted\nconst A = "%s" #! dep\nconst H = preload("%s")\nconst Leaf = H.Leaf\n' % [asset, clean_hub])
	var g5 = make.call(unrelated, {})
	_check("tag: the walking file's own tag does not block", g5.has(clean_hub), false)
	_check("tag: and still fires", g5.has(asset), true)


static func _edge_from(graph, from:String, to:String):
	for edge in graph.get_out_edges(from):
		if edge.to == to:
			return edge
	return null


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
