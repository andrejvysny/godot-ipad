class_name LiveHarness
extends RefCounted
## Sender + fake link + replica around a real WorldDocument, driven the way EditorSession drives history:
## operations mutate the document inside an EditTransaction, commit() bumps the revision and pushes history, then
## notifies the sender exactly as the world_committed signal does.

const SESSION := "0123456789abcdef0123456789abcdef"
const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"

var doc: WorldDocument
var catalog: AssetCatalog
var history := CommandHistory.new()
var sender := LiveSender.new()
var replica: LiveReplica
var link: FakeLiveLink
var tx_open: EditTransaction = null
var root := ""


func setup(scratch: String, layout: WorldLayout = null) -> void:
	root = scratch
	catalog = AssetCatalog.load_from()[0]
	doc = WorldDocument.create_flat(0.0, ControlCodec.grass_value(), layout, catalog)
	sender.spool = LiveSpool.new(scratch + "/spool")
	sender.scratch_root = scratch + "/tmp"
	sender.created_with = WorldCodec.default_created_with()
	sender.tx_provider = func() -> EditTransaction: return tx_open
	replica = LiveReplica.new(SESSION, catalog, scratch + "/replica")
	link = FakeLiveLink.new(sender, replica)


## Attaches the document, opens the session and waits for the initial snapshot to be installed.
func connect_and_sync() -> void:
	sender.set_document(doc)
	sender.start_session(SESSION)
	link.settle()


func binding(asset: String) -> String:
	return doc.assets.bundled_binding_for(asset)


## Runs `mutator(tx)` in a transaction and commits the result. False for a no-op.
func run(mutator: Callable) -> bool:
	var tx := EditTransaction.new()
	tx.begin(doc, "test", "Test op")
	mutator.call(tx)
	var change := tx.finish()
	if change == null:
		return false
	commit(change)
	return true


func commit(change: WorldChange) -> void:
	doc.bump_revision()
	history.push_already_applied(change)
	sender.on_committed(change, doc.document_revision, true)


func undo() -> bool:
	var change := history.undo(doc)
	if change == null:
		return false
	sender.on_committed(change, doc.document_revision, false)
	return true


func redo() -> bool:
	var change := history.redo(doc)
	if change == null:
		return false
	sender.on_committed(change, doc.document_revision, true)
	return true


# --- Operations -----------------------------------------------------------------------------------

func sculpt(loc: Vector2i, sample_index: int, dh: float, count: int = 1) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_heights(loc)
		var r := doc.get_region(loc)
		for i in count:
			r.heights[(sample_index + i * 257) % WorldConstants.REGION_SAMPLE_COUNT] += dh
		doc.invalidate_height_range(loc))


func paint(loc: Vector2i, sample_index: int, blend: int) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_controls(loc)
		var r := doc.get_region(loc)
		r.control[sample_index] = ControlCodec.encode_paint(r.control[sample_index] & 0xFFFFFFFF, blend))


func tint(loc: Vector2i, sample_index: int, rgba: PackedByteArray) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_colors(loc)
		var r := doc.get_region(loc)
		for c in 4:
			r.color[sample_index * 4 + c] = rgba[c])


func hole(loc: Vector2i, sample_index: int) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_controls(loc)
		var r := doc.get_region(loc)
		r.control[sample_index] = (r.control[sample_index] & 0xFFFFFFFF) | ControlCodec.HOLE_BIT)


func place(asset: String, x: float, z: float) -> String:
	var id := ObjectRecord.new_uuid_v4()
	var ok := run(func(tx: EditTransaction) -> void:
		tx.capture_object(id)
		var rec := ObjectRecord.new()
		rec.object_id = id
		rec.binding_id = binding(asset)
		rec.set_position(x, doc.sample_height(x, z), z)
		doc.put_object(rec))
	return id if ok else ""


func move(id: String, x: float, z: float) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_object(id)
		var rec := doc.get_object(id).clone()
		rec.set_position(x, doc.sample_height(x, z), z)
		doc.put_object(rec))


func rebind(id: String, asset: String) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_object(id)
		var rec := doc.get_object(id).clone()
		rec.binding_id = binding(asset)
		doc.put_object(rec))


func delete_object(id: String) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_object(id)
		doc.remove_object(id))


func scatter_add(asset: String, points: Array) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_scatter()
		for p: Vector2 in points:
			doc.scatter.add(binding(asset), p.x, p.y, 0.5, 1.0, 0))


func scatter_erase(indices: PackedInt32Array) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_scatter()
		doc.scatter.remove_indices(indices))


func path_set(id: String, points: PackedVector2Array) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_path(id)
		var rec := PathRecord.new()
		rec.path_id = id
		rec.width_m = 2.0
		rec.points = points
		doc.put_path(rec))


func path_delete(id: String) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_path(id)
		doc.remove_path(id))


func rules(slope: int) -> bool:
	return run(func(tx: EditTransaction) -> void:
		tx.capture_rules()
		doc.rules.rock_slope_deg = slope)


## Settles the link and asserts the replica reproduces the sender's authored hash, computed independently.
func verify(tc: TestCase, label: String) -> void:
	link.settle()
	tc.assert_eq(replica.stats.resyncs, 0, "%s: replica asked for a resync: %s" % [label, replica.stats.last_resync])
	var want := CanonicalEncoder.authored_hash(doc)
	tc.assert_eq(replica.revision(), doc.document_revision, "%s: revision (resync: %s)" % [label, replica.stats.last_resync])
	tc.assert_eq(replica.authored_hash(), want, label + ": replica cache hash")
	if replica.document != null:
		tc.assert_eq(CanonicalEncoder.authored_hash(replica.document), want, label + ": replica recomputed hash")
