class_name AssetColors
extends RefCounted
## Weight-bar colours of assets (docs/editor-v2.md §9, last paragraph). Unknown assets get a stable
## colour derived from the id.

const KEYS := {"cabin": Color("c08a5a"), "lodge": Color("c08a5a"), "spruce": Color("3d8a4a"),
		"boulder": Color("9a958c"), "grass": Color("8fc050"), "fern": Color("2f6b26"),
		"flower": Color("e9c84a"), "pebble": Color("c7c2b8")}


static func of(asset_id: String) -> Color:
	for key: String in KEYS:
		if asset_id.contains(key):
			return KEYS[key]
	return Color.from_hsv(float(asset_id.hash() % 360) / 360.0, 0.45, 0.75)
