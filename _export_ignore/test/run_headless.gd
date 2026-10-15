extends SceneTree
## Clean-compile headless entry for dep_map's suites, exiting with a CI code.
##     godot --headless --path . --script res://addons/_lib/dep_map/_export_ignore/test/run_headless.gd
##
## The scanner and the layout are pure over user:// fixtures. GraphUI itself is a GraphEdit and
## needs a live editor, so it is checked by eye with GraphUI.preview_window().

const SUITES:PackedStringArray = [
	"res://addons/_lib/dep_map/_export_ignore/test/scanner_test.gd",
	"res://addons/_lib/dep_map/_export_ignore/test/layout_test.gd",
]

func _init() -> void:
	var success = true
	var output:Array[String] = []

	for path in SUITES:
		var res:Dictionary = load(path).run_tests()
		success = success and res.result == 0
		output.append_array(res.output)

	print("\n".join(output))
	quit(0 if success else 1)
