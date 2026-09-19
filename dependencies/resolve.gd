## Turns a reference as written into an absolute res:// path. Returns "" when it cannot -
## a dead uid or an unresolvable relative path is reported as unresolved rather than
## silently becoming an empty dependency key.

const UFile = preload("uid://bl33psa06nv1e") #! resolve ALibRuntime.Utils.UFile.Methods

const UID_PREFIX = "uid" + "://"


static func to_path(raw:String, current_file_path:String) -> String:
	if raw == "":
		return ""
	if raw.begins_with(UID_PREFIX):
		if UFile.uid_invalid(raw):
			return ""
		return UFile.uid_to_path(raw)
	if raw.is_absolute_path():
		return raw.simplify_path()
	if current_file_path == "":
		return ""
	return UFile.path_from_relative(raw, current_file_path)


## Rejects the many quoted strings in a script that are not paths at all, so tag handlers
## and loose scans do not have to guess.
static func looks_like_path(raw:String) -> bool:
	if raw == "" or raw.contains("\n"):
		return false
	if raw.begins_with(UID_PREFIX):
		return true
	if raw.get_extension() == "":
		return false
	return raw.get_file().is_valid_filename()
