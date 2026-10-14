## One reference from a file to another. Every reference is kept - a script preloaded from
## three places produces three edges - so the graph stays traversable in both directions.
## `raw` holds the reference exactly as written, before uid/relative resolution.

enum Kind {
	PRELOAD,        ## preload("...")
	LOAD,           ## load("...") / ResourceLoader.load("...")
	EXTENDS_PATH,   ## extends "..."
	EXTENDS_CLASS,  ## extends SomeGlobalClass
	GLOBAL_CLASS,   ## bare global class name used in the body
	EXT_RESOURCE,   ## [ext_resource ...] in a .tscn/.tres
	SCRIPT_CLASS,   ## script_class="..." on a .tres header
	TAG,            ## produced by a registered #! tag handler
}

const KIND_NAMES:Array[String] = [
	"preload", "load", "extends_path", "extends_class",
	"global_class", "ext_resource", "script_class", "tag",
]

## Meta keys the scanners write. An edge carrying RESOLVED_FROM came from a dotted access path
## rather than a bare reference, and CONSUMED says how many of its segments named files - so
## `parts[consumed - 1]` is the segment that landed on `to`, and the rest is an unresolved tail.
const META_RESOLVED_FROM = "resolved_from"
const META_PARTIAL = "partial"
const META_CONSUMED = "consumed"
const META_HEAD_FROM_CLASS_MAP = "head_from_class_map"

## Path of the file holding the reference.
var from:String
## Resolved absolute path of the referenced file. "" when resolution failed.
var to:String
var kind:int = Kind.PRELOAD
## 1-based. 0 when the edge was not derived from a single line.
var line_no:int = 0
## The reference as written: "uid://abc", "./foo.gd", "ScriptDock".
var raw:String
## Tag name without the "#!" prefix. "" unless kind == TAG.
var tag:String = ""
## Whatever the tag handler returned, or scanner-supplied extras.
var meta:Dictionary = {}


func _init(_from:String="", _to:String="", _kind:int=Kind.PRELOAD, _line_no:int=0, _raw:String="", _tag:String="") -> void:
	from = _from
	to = _to
	kind = _kind
	line_no = _line_no
	raw = _raw
	tag = _tag


func resolved() -> bool:
	return to != ""


func kind_name() -> String:
	if kind < 0 or kind >= KIND_NAMES.size():
		return "unknown"
	return KIND_NAMES[kind]


func to_dict() -> Dictionary:
	return {
		"from": from,
		"to": to,
		"kind": kind_name(),
		"line_no": line_no,
		"raw": raw,
		"tag": tag,
		"meta": meta,
	}


func _to_string() -> String:
	var target = to if to != "" else "<unresolved:%s>" % raw
	return "%s -[%s]-> %s (%s:%d)" % [from.get_file(), kind_name(), target, from.get_file(), line_no]
