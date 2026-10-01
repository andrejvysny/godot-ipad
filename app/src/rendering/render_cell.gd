class_name RenderCell
extends RefCounted
## One ownership cell of ObjectRenderWorld: its members by asset and the batches built for them.

var key := Vector2i.ZERO
var origin := Vector3.ZERO
var members: Dictionary = {}  # asset_id -> Dictionary(id -> true)
var reps: Dictionary = {}  # asset_id -> representation of the built group
var batches: Dictionary = {}  # "<asset>|<rep>" -> InstanceBatch
