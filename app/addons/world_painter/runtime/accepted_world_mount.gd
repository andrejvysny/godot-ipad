class_name WPAcceptedWorldMount
extends Node3D
## Mounts the baked scene of an accepted world (ADR 0017 A6). Game scripts, lights, the player and overrides live
## outside the generated root, as siblings of this node. The mount loads nothing but the binding's PackedScene.

@export var binding: WPAcceptedWorldBinding

var mounted: Node


func _ready() -> void:
	mount()


## Instantiates the binding's scene once. False when there is nothing to mount.
func mount() -> bool:
	if mounted != null or binding == null or binding.scene == null:
		return mounted != null
	mounted = binding.scene.instantiate()
	add_child(mounted)
	return true
