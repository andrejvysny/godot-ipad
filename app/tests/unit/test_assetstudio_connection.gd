extends TestCase
## AssetStudioConnection: device-local configuration under user://, token handling and the cleartext warning.

const SERVER := "6f1c2a52-3c2e-4d4b-9a57-0b6f6f0c1d2e"
const TOKEN := "tok-secret-1234567890"

var dir := ""
var conn: AssetStudioConnection


func before_each() -> void:
	dir = scratch_dir() + "/assetstudio"
	conn = AssetStudioConnection.new(dir, dir + "/cache")


func test_https_connection_is_stored_with_the_token_in_the_credentials_file_only() -> void:
	assert_false(conn.has_connection())
	assert_empty_string(conn.configure(SERVER, "https://assets.example.com", TOKEN))
	assert_true(conn.has_connection())
	assert_eq(conn.server_ids(), PackedStringArray([SERVER]))
	assert_eq(conn.warnings(), PackedStringArray())
	assert_false(FileAccess.get_file_as_string(dir.path_join("connections.json")).contains(TOKEN))
	assert_true(FileAccess.get_file_as_string(dir.path_join("credentials.json")).contains(TOKEN))
	assert_true(dir.begins_with("user://"), "never res://")
	assert_true(AssetStudioConnection.new(dir, dir + "/cache").has_connection(), "survives a restart")


func test_cleartext_lan_needs_the_explicit_flag_and_shows_a_warning() -> void:
	allow_logged_errors()  # the vendored registry also push_warning()s when a cleartext LAN endpoint is stored
	var refused := conn.configure(SERVER, "http://192.168.1.20:8080", TOKEN)
	assert_error_contains(refused, "allow_insecure_lan")
	assert_false(refused.contains(TOKEN), "errors never carry the token")
	assert_false(conn.has_connection())
	assert_empty_string(conn.configure(SERVER, "http://192.168.1.20:8080", TOKEN, true))
	var warning := conn.warning_for(SERVER)
	assert_error_contains(warning, "192.168.1.20")
	assert_false(warning.contains(TOKEN))
	assert_eq(conn.warnings().size(), 1)
	assert_empty_string(conn.configure(SERVER, "http://127.0.0.1:8080", TOKEN))
	assert_eq(conn.warning_for(SERVER), "", "loopback needs no warning")


func test_resolvers_follow_the_connection_and_the_offline_flag() -> void:
	var parent := Node.new()
	tree.root.add_child(parent)
	assert_true(conn.build_resolvers(parent).is_empty(), "no connection: the exact cache only")
	assert_empty_string(conn.configure(SERVER, "https://assets.example.com", TOKEN))
	conn.offline_only = true
	var resolvers := conn.build_resolvers(parent)
	assert_eq(resolvers.keys(), [SERVER])
	assert_true(bool((resolvers[SERVER] as Node).get("offline_only")))
	conn.shutdown()
	tree.root.remove_child(parent)
	parent.free()
