class_name InputProvider
extends Node
## Platform input boundary (spec §4.3, §6). Exactly one provider is authoritative per session.
## Providers own platform events and metadata only; they never edit or route.

## Emitted when the provider stops delivering trustworthy input (bridge lost, overflow).
## The input system must cancel all active operations when this fires.
signal provider_failed(reason: String)

const SPACE_VIEWPORT := "viewport"  ## position_raw already in root-viewport coordinates
const SPACE_UIKIT_POINTS := "uikit_points"  ## UIKit points in the Godot view's coordinate space


func provider_name() -> String:
	return "abstract"


## Development providers must be visibly labelled and never satisfy an iPad gate.
func is_development() -> bool:
	return false


func is_available() -> bool:
	return false


## {source_identity: bool, pressure: bool, tilt: bool, coalesced: bool,
##  native_cancel: bool, native_timestamps: bool}
func capabilities() -> Dictionary:
	return {}


func coordinate_space() -> String:
	return SPACE_VIEWPORT


## For SPACE_UIKIT_POINTS: {view_size_points: Vector2, content_scale: float, safe_area: Rect2}.
func view_metrics() -> Dictionary:
	return {}


## Samples in arrival order since the last call (timestamp-ordered per contact).
func drain_samples() -> Array[PointerSample]:
	return []


## Emits CANCEL for every active contact on the next drain and ignores further events from
## those contacts until they physically end.
func cancel_all(_reason: String) -> void:
	pass


## Current time on the same clock as PointerSample.timestamp_s.
func now_seconds() -> float:
	return Time.get_ticks_usec() / 1_000_000.0


func diagnostics() -> Dictionary:
	return {}
