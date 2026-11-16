## JSON file persistence for accounts and the player market.
## Data lives in <data_dir>/accounts/<name>.json and <data_dir>/market.json.
extends RefCounted

var data_dir := "user://server_data"


func _init(dir: String) -> void:
	data_dir = dir
	DirAccess.make_dir_recursive_absolute(data_dir + "/accounts")


func _account_path(username: String) -> String:
	return "%s/accounts/%s.json" % [data_dir, username.to_lower()]


func account_exists(username: String) -> bool:
	return FileAccess.file_exists(_account_path(username))


func load_account(username: String) -> Dictionary:
	return _read_json(_account_path(username))


func save_account(acc: Dictionary) -> void:
	_write_json(_account_path(acc.username), acc)


func load_market() -> Dictionary:
	var m := _read_json(data_dir + "/market.json")
	if m.is_empty():
		m = {"next_id": 1, "listings": []}
	return m


func save_market(m: Dictionary) -> void:
	_write_json(data_dir + "/market.json", m)


static func hash_password(password: String, salt: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var data := (salt + ":" + password).to_utf8_buffer()
	for _i in 1000: # cheap key stretching
		ctx.update(data)
	return ctx.finish().hex_encode()


static func make_salt() -> String:
	var c := Crypto.new()
	return c.generate_random_bytes(16).hex_encode()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _write_json(path: String, d: Dictionary) -> void:
	# Write to a temp file then rename so a crash can't corrupt saves.
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write " + tmp)
		return
	f.store_string(JSON.stringify(d, "\t"))
	f.close()
	DirAccess.rename_absolute(tmp, path)
