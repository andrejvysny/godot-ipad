class_name RenderCell
extends RefCounted
## One ownership cell of ObjectRenderWorld: its members by asset and the batches built for them.

var key := Vector2i.ZERO
var origin := Vector3.ZERO
var members: Dictionary = {}  # asset_id -> Dictionary(id -> true)
var reps: Dictionary = {}  # asset_id -> representation of the built group
var batches: Dictionary = {}  # "<asset>|<rep>" -> InstanceBatch
var role: String = ""  # committed individual role the groups of this cell are built for
var wanted: String = ""  # latest LOD evaluation; applied to `role` once navigation settled and the cell is unpinned
var y_lo: float = INF  # member origin heights, only used to measure the LOD distance
var y_hi: float = -INF
