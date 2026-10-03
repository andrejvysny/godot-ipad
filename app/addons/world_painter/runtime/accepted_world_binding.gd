class_name WPAcceptedWorldBinding
extends Resource
## Tracked pointer of an accepted world (INT-SPEC-1.1 §11, ADR 0017 A5): which generation is active and the baked
## scene to instance. Local resources only; it never contacts AssetStudio, a server or the live preview.

@export var world_id: String = ""
@export var source_snapshot_hash: String = ""
@export var authored_hash: String = ""
@export var generation_id: String = ""
@export var scene: PackedScene
