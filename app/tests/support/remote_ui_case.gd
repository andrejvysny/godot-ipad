class_name RemoteUiCase
extends UiTestCase
## UiTestCase plus a session whose Library has a fake AssetStudio server (one asset, versions v1/v2/v3) and a
## FakeAssetProvider serving the contract GLB for every binding, so tiles, drops and update reviews run offline.

const LIB := FakeLibraryClient.LIBRARY
const SERVER := AssetTestKit.SERVER
const ASSET := AssetTestKit.ASSET
const V1 := AssetTestKit.V1_ID
const V2 := AssetTestKit.V2_ID
const V3 := "ver_00000000000000v3"

var client: FakeLibraryClient
var provider: FakeAssetProvider


func before_each() -> void:
	super()
	SessionAssets.storage_dir = scratch_dir() + "/assetstudio"


func after_each() -> void:
	super()
	SessionAssets.storage_dir = AssetStudioConnection.DIR


func _remote_session() -> EditorSession:
	var s := await _start()
	client = FakeLibraryClient.new()
	var row := FakeLibraryClient.row(1, "Crate")
	row.asset_id = ASSET
	row.current_version_id = V1
	client.items[LIB] = [row]
	client.current[ASSET] = V1
	client.add_version(V1, AssetTestKit.descriptor_text("primitive_prop.json"))
	client.add_version(V2, AssetTestKit.descriptor_text("primitive_prop_v2.json"))
	var v2_text := AssetTestKit.descriptor_text("primitive_prop_v2.json")
	assert_true(v2_text.contains('"scale_range":["0.5","2"]'))
	assert_true(v2_text.contains('"version_id":"%s"' % V2))
	client.add_version(V3, v2_text.replace('"scale_range":["0.5","2"]', '"scale_range":["0.5","1.5"]').replace(
			'"version_id":"%s"' % V2, '"version_id":"%s"' % V3))
	provider = FakeAssetProvider.new()
	provider.default_glb = AssetTestKit.glb(AssetTestKit.GLB_V1)
	s.assets().replace_assetstudio_provider(provider)
	s.assets().remote.set_clients({SERVER: client}, false)
	await s.assets().remote.refresh_libraries()
	s.assets().remote.select(RemoteLibrary.key_of(SERVER, LIB))
	await _frames(3)
	return s


func _key(version: String = V1) -> String:
	return AssetBinding.Canonical.asset_key(SERVER, LIB, ASSET, version)


func _tile(s: EditorSession, version: String = V1) -> RemoteTile:
	return _ui(s).library().remote_view().tile(_key(version))


func _download(s: EditorSession) -> String:
	var tile := _tile(s)
	await _pencil_click(s, tile.action_button())
	for i in 300:
		if tile.readiness().state == RemotePrep.READY:
			break
		await tree.process_frame
	assert_eq(tile.readiness().state, RemotePrep.READY)
	return str(tile.readiness().binding_id)


## One drop of the selection at `pos` through the tool API (the tile drag itself is covered separately).
func _place(s: EditorSession, selection: Variant, pos: Vector2) -> String:
	assert_empty_string(s.tools.begin_drop(selection))
	s.tools.update_drop(pos, false)
	s.tools.finish_drop(pos, false)
	return s.tools.selected_id()
