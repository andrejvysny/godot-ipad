class_name WorldAssetProviders
extends WPAssetProvider
## Router of the providers of the open world: every call goes to the provider named by the binding's `provider`.
## It also pins and prepares everything a document references, per owner (one owner per open world).

var _providers: Dictionary = {}  # provider id -> WPAssetProvider


func provider_id() -> String:
	return "router"


func add_provider(provider: WPAssetProvider) -> void:
	_providers[provider.provider_id()] = provider
	provider.prepared.connect(prepared.emit)


func provider_of(binding_id: String) -> WPAssetProvider:
	var b: AssetBinding = assets.get_binding(binding_id) if assets != null else null
	return _providers.get(b.provider) if b != null else null


func attach(lock: WorldAssetLock) -> void:
	assets = lock
	for p: WPAssetProvider in _providers.values():
		p.attach(lock)


func describe(binding_id: String) -> Dictionary:
	var p := provider_of(binding_id)
	return p.describe(binding_id) if p != null else {}


func prepare(binding_id: String, cancel: RefCounted = null) -> void:
	var p := provider_of(binding_id)
	if p != null:
		p.prepare(binding_id, cancel)
	else:
		prepared.emit.call_deferred(binding_id, false, "no provider for this binding")


func is_prepared(binding_id: String) -> bool:
	var p := provider_of(binding_id)
	return p != null and p.is_prepared(binding_id)


func representation(binding_id: String, tier: String) -> Mesh:
	var p := provider_of(binding_id)
	return p.representation(binding_id, tier) if p != null else null


func instantiate(binding_id: String) -> Node3D:
	var p := provider_of(binding_id)
	return p.instantiate(binding_id) if p != null else null


func pin(owner: String, binding_ids: PackedStringArray) -> void:
	var by_provider := {}
	for id in binding_ids:
		var p := provider_of(id)
		if p != null:
			if not by_provider.has(p):
				by_provider[p] = PackedStringArray()
			(by_provider[p] as PackedStringArray).append(id)
	for p: WPAssetProvider in _providers.values():
		p.pin(owner, by_provider.get(p, PackedStringArray()))


func unpin(owner: String) -> void:
	for p: WPAssetProvider in _providers.values():
		p.unpin(owner)


func cancel(binding_id: String) -> void:
	var p := provider_of(binding_id)
	if p != null:
		p.cancel(binding_id)


func cancel_all() -> void:
	for p: WPAssetProvider in _providers.values():
		p.cancel_all()


func pending_count() -> int:
	var n := 0
	for p: WPAssetProvider in _providers.values():
		n += p.pending_count()
	return n


## Pins every AssetStudio binding `doc` references for `owner` and starts preparing the ones that are not
## prepared yet. Returns the ids whose preparation was started.
func prepare_referenced(doc: WorldDocument, owner: String) -> PackedStringArray:
	var remote := PackedStringArray()
	for id in doc.assets.referenced_ids(doc):
		var b := doc.assets.get_binding(id)
		if b != null and not b.is_bundled():
			remote.append(id)
	pin(owner, remote)
	var started := PackedStringArray()
	for id in remote:
		if not is_prepared(id):
			prepare(id)
			started.append(id)
	return started
