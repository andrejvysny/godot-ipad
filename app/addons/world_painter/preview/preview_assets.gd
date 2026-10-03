class_name PreviewAssets
extends RefCounted
## Asset providers of the preview child (ADR 0016 P3/P4): the bundled catalog provider plus AssetStudioProvider fed by
## a BrokerAssetResolver, so remote bindings are prepared from broker-verified cache files only. Owns no nodes except
## the resolver (freed with this object).

signal asset_ready(binding_id: String)

const OWNER := "preview"

var providers := WorldAssetProviders.new()
var registry: RenderAssetRegistry
var cache: RenderAssetCache
var assetstudio: AssetStudioProvider
var resolver := BrokerAssetResolver.new()

var _lock: WorldAssetLock
var _servers: Dictionary = {}


func _init(catalog: AssetCatalog, client: PreviewBrokerClient, blob_root: String) -> void:
	var config := RenderConfig.load_from()
	var budgets := config.section("budgets")
	if RenderingServer.get_rendering_device() == null:
		budgets.inflight_loads = 1  # the dummy renderer's storage is not thread-safe
	registry = RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	cache = RenderAssetCache.new(budgets)
	resolver.client = client
	resolver.blob_root = blob_root
	resolver.lock_getter = func() -> WorldAssetLock: return _lock
	assetstudio = AssetStudioProvider.new(null)
	assetstudio.bind_render(registry, cache)
	providers.add_provider(BundledProvider.new(registry, cache))
	providers.add_provider(assetstudio)
	providers.prepared.connect(_on_prepared)


## Profile material hook (ADR 0016 P4): call before the first snapshot is attached.
func set_material_mapper(mapper: WPMaterialMapper) -> void:
	cache.mesh_mapper = mapper
	assetstudio.material_mapper = mapper


## The displayed document's lock changed identity or content: bind it, pin what it references and prepare it.
func attach(doc: WorldDocument) -> void:
	_lock = doc.assets
	providers.attach(_lock)
	for id in _lock.ids():
		var b := _lock.get_binding(id)
		if b != null and not b.is_bundled() and not _servers.has(b.asset_ref.server_id):
			_servers[b.asset_ref.server_id] = true
			assetstudio.add_resolver(b.asset_ref.server_id, resolver)
	providers.prepare_referenced(doc, OWNER)


## Bindings the document references that are not usable yet: {binding_id: reason}.
func missing(doc: WorldDocument) -> Dictionary:
	return doc.assets.availability(doc).unavailable


func _on_prepared(binding_id: String, ok: bool, error: String) -> void:
	if ok and error == "":
		asset_ready.emit(binding_id)


func shutdown() -> void:
	providers.cancel_all()
	providers.unpin(OWNER)
	resolver.free()
	assetstudio.shutdown()
