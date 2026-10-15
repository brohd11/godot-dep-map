@tool
extends GraphNode
## One file in the dependency graph.
##
## A GraphNode slot is bound to a child row by index, so N ports means N child rows. One row
## per reference kind, and both sides of the row use that kind's colour: GraphEdit draws a
## connection as a gradient between the source and target port colours, so a neutral input
## port washes every line out to grey. Matching kind to kind on both ends keeps the line the
## colour of what it means.
##
## The node ends up documenting its own edges - left port lit means "something pulls this in
## that way", right port lit means "this file references out that way".

const KindStyle = preload("res://addons/_lib/dep_map/src/graph_ui/kind_style.gd")

const ROW_HEIGHT = 22.0
const TITLE_HEIGHT = 34.0
const NODE_WIDTH = 230.0

signal activated(path:String)

var path:String = ""
var compact:bool = false
## {Kind: port index} for the connect pass. Ports are counted per side, so a kind that only
## appears on one side still gets the right index there.
var out_port_of_kind:Dictionary = {}
var in_port_of_kind:Dictionary = {}

var _icon_rect:TextureRect
var _last_click_ms:int = 0


## `dep_node` may be null for an unresolved stub, in which case `raw` labels it.
##
## `in_kinds` / `out_kinds` are {Kind: true} sets of the edges the panel is actually going to
## draw. Rows are built from those rather than from every edge on the DepNode, so a tree view
## - where each node has one incoming edge - collapses to one or two rows on its own, without
## a separate "compact" mode that would break the port colouring.
static func create(_path:String, dep_node, raw:String = "", in_kinds:Dictionary = {}, out_kinds:Dictionary = {}) -> GraphNode:
	var ins = new()
	ins.path = _path
	ins.compact = in_kinds.size() + out_kinds.size() <= 1
	ins._build(dep_node, raw, in_kinds, out_kinds)
	return ins


func _build(dep_node, raw:String, in_kinds:Dictionary, out_kinds:Dictionary) -> void:
	var scale = KindStyle.get_scale()
	custom_minimum_size = Vector2(NODE_WIDTH, 0.0) * scale
	resizable = false
	draggable = true
	selectable = true

	if dep_node == null:
		_build_unresolved(raw)
		return

	title = _title_for(path)
	tooltip_text = _tooltip_for(dep_node)

	var kinds = _union_kinds(in_kinds, out_kinds)

	if kinds.is_empty():
		# an isolated file still needs one row - a GraphNode with no children has no body
		_add_row("", Color.TRANSPARENT, dep_node)
	else:
		var in_port := 0
		var out_port := 0
		for i in kinds.size():
			var kind:int = kinds[i]
			var color = KindStyle.get_color(kind)
			var has_in:bool = in_kinds.has(kind)
			var has_out:bool = out_kinds.has(kind)
			# a single-row node is already unambiguous; the label is only earning its space
			# once there is more than one kind to tell apart
			_add_row("" if compact else KindStyle.get_short(kind), color, dep_node if i == 0 else null)
			set_slot(i, has_in, 0, color, has_out, 0, color)
			if has_in:
				in_port_of_kind[kind] = in_port
				in_port += 1
			if has_out:
				out_port_of_kind[kind] = out_port
				out_port += 1

	_apply_state(dep_node)


func _build_unresolved(raw:String) -> void:
	title = "unresolved"
	tooltip_text = "Could not resolve:\n%s" % raw
	var label = Label.new()
	label.text = raw if raw != "" else "?"
	label.add_theme_color_override("font_color", KindStyle.UNRESOLVED_COLOR)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(0.0, ROW_HEIGHT * KindStyle.get_scale())
	add_child(label)
	set_slot(0, true, 0, KindStyle.UNRESOLVED_COLOR, false, 0, Color.TRANSPARENT)
	_set_title_color(KindStyle.UNRESOLVED_COLOR)


# The icon goes on the first row rather than the title, which GraphNode does not let us
# decorate directly.
func _add_row(text:String, color:Color, dep_node) -> void:
	var row = HBoxContainer.new()
	row.custom_minimum_size = Vector2(0.0, ROW_HEIGHT * KindStyle.get_scale())

	if dep_node != null:
		var icon = KindStyle.get_file_icon(path)
		if icon != null:
			_icon_rect = TextureRect.new()
			_icon_rect.texture = icon
			_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			_icon_rect.custom_minimum_size = Vector2(16, 16) * KindStyle.get_scale()
			row.add_child(_icon_rect)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	if text != "":
		var label = Label.new()
		label.text = text
		label.add_theme_color_override("font_color", color)
		label.add_theme_font_size_override("font_size", int(11 * KindStyle.get_scale()))
		row.add_child(label)

	add_child(row)


func _apply_state(dep_node) -> void:
	if not dep_node.exists:
		_set_title_color(KindStyle.MISSING_COLOR)
		modulate.a = 0.75
		tooltip_text += "\n(file not found)"
	elif dep_node.is_root:
		_set_title_color(KindStyle.ROOT_COLOR)
	elif not dep_node.scanned:
		modulate.a = 0.85


func _set_title_color(color:Color) -> void:
	add_theme_color_override("title_color", color)


## Title-colour like a root: this node is the anchor of the panel's neighbourhood view.
func mark_focused() -> void:
	_set_title_color(KindStyle.ROOT_COLOR)


func _title_for(_path:String) -> String:
	var file = _path.get_file()
	return file if file != "" else _path


func _tooltip_for(dep_node) -> String:
	var lines:Array[String] = [path]
	var uid:String = dep_node.get_uid()
	if uid != "":
		lines.append(uid)
	lines.append("depth %d · %d dependents · %d dependencies" % [
		dep_node.depth, dep_node.get_dependent_paths().size(), dep_node.get_dependency_paths().size()])
	return "\n".join(lines)


## GraphNode has no "activated" of its own, so double-click is detected here.
func _gui_input(event:InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if event.double_click:
			activated.emit(path)
			accept_event()


## Fallback size for the layout when a node's real minimum is not available yet.
static func estimate_size(dep_node) -> Vector2:
	var rows = 1
	if dep_node != null:
		rows = maxi(row_kinds(dep_node).size(), 1)
	var scale = KindStyle.get_scale()
	return Vector2(NODE_WIDTH, TITLE_HEIGHT + rows * ROW_HEIGHT) * scale


## The kinds this file gets a row for: everything it is referenced by, plus everything it
## references. Enum order, so a file always lays its rows out the same way.
static func row_kinds(dep_node) -> Array:
	return _union_kinds(_kinds_of(dep_node.in_edges), _kinds_of(dep_node.out_edges))


# Unresolved out-edges (to == "") count too: they still need a port, so the line to the
# red stub node leaves from the row that explains it.
static func _kinds_of(edges:Array) -> Dictionary:
	var seen = {}
	for edge in edges:
		seen[edge.kind] = true
	return seen


static func _union_kinds(a:Dictionary, b:Dictionary) -> Array:
	var seen = a.duplicate()
	seen.merge(b)
	var kinds:Array = seen.keys()
	kinds.sort()
	return kinds
