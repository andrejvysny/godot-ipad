class_name LodPolicy
extends RefCounted
## Representation choice by projected size (spec §4.2, §8.1, §9.1). Pure logic shared by the object
## and scatter renderers and the overview groups. Distances are normalised to a reference view, so a
## wider FOV or a smaller viewport makes the same object coarser at the same metric distance; the
## profile radii are the detail targets at the reference view, never disappearance distances.
## Roles from fine to coarse: near, mid, far, group128, group256 (near only when the profile's
## minimum unselected tier is "near").

const REFERENCE_FOV_DEG := 60.0
const REFERENCE_VIEWPORT_H := 820.0
const NEAR_FRACTION := 0.35
# Individual far representations up to R * GROUP_FACTOR. 2.5 measured ~2.9 M primitives in a dense 50k-object
# focus view (HOST); 1.6 hands the outer ring to the overview groups sooner (Performance: 128 m).
const GROUP_FACTOR := 1.6
const GROUP256_FACTOR := 2.0  # 128 m groups up to 2 x the group threshold, 256 m groups beyond

const NEAR := "near"
const MID := "mid"
const FAR := "far"
const GROUP128 := "group128"
const GROUP256 := "group256"


## Metric distance scaled to the reference FOV and viewport height (same projected size).
static func effective_distance(distance_m: float, fov_deg: float, viewport_h: float) -> float:
	var fov_scale := tan(deg_to_rad(clampf(fov_deg, 1.0, 179.0)) * 0.5) / tan(deg_to_rad(REFERENCE_FOV_DEG) * 0.5)
	return distance_m * fov_scale * REFERENCE_VIEWPORT_H / maxf(viewport_h, 1.0)


## Roles available to `profile`, fine to coarse.
static func roles(profile: Dictionary) -> PackedStringArray:
	if str(profile.get("near_min_role", MID)) == NEAR:
		return PackedStringArray([NEAR, MID, FAR, GROUP128, GROUP256])
	return PackedStringArray([MID, FAR, GROUP128, GROUP256])


## Upper effective distance of each role in roles(profile) except the last (which is unbounded).
static func thresholds(profile: Dictionary) -> PackedFloat64Array:
	var r := float(profile.get("tree_detail_radius_m", 80.0))
	var group := r * GROUP_FACTOR
	var out := PackedFloat64Array()
	if str(profile.get("near_min_role", MID)) == NEAR:
		out.append(r * NEAR_FRACTION)
	out.append_array(PackedFloat64Array([r, group, group * GROUP256_FACTOR]))
	return out


## Role for `effective_m`. With a valid `current` role a change needs the distance to clear the
## boundary by half of `hysteresis` (fraction) on the side it moves to, so a camera resting near a
## threshold never toggles (LOD-01). Ties resolve to the current role.
static func role_for(effective_m: float, profile: Dictionary, current: String = "", hysteresis: float = 0.2) -> String:
	var names := roles(profile)
	var limits := thresholds(profile)
	var raw := _index(effective_m, limits, 1.0)
	var cur := names.find(current)
	if cur < 0 or raw == cur:
		return names[raw]
	if raw > cur:
		return names[maxi(cur, _index(effective_m, limits, 1.0 + hysteresis * 0.5))]
	return names[mini(cur, _index(effective_m, limits, 1.0 - hysteresis * 0.5))]


## Individual (cell batch) role: group roles clamp to far; the overview decides grouping itself.
static func individual_role(effective_m: float, profile: Dictionary, current: String = "", hysteresis: float = 0.2) -> String:
	var role := role_for(effective_m, profile, current, hysteresis)
	return FAR if role == GROUP128 or role == GROUP256 else role


## Decorative ground cover keeps a representative density while navigating (PREF-08): full profile density
## inside the ground-cover radius, then halving per band so the on-screen density stays roughly constant
## (ground area per pixel grows with distance squared), and not drawn beyond GROUND_COVER_BANDS bands.
## Band k covers effective distances [r * sqrt(2)^(k-1), r * sqrt(2)^k) for k >= 1 (band 0 is inside r);
## its density factor is 0.5^k. Returns -1 when not drawn.
const GROUND_COVER_BANDS := 4  # factors 1, 1/2, 1/4, 1/8, 1/16 up to 4 r


static func ground_cover_band(effective_m: float, profile: Dictionary, current: int = -2, hysteresis: float = 0.2) -> int:
	var radius := float(profile.get("ground_cover_radius_m", 25.0))
	var raw := _band(effective_m, radius, 1.0)
	if current < -1 or raw == current:
		return raw
	if current == -1:
		# Not drawn: appear only clearly inside the outer band; the band itself is the raw one, so a cell
		# that (re)appears gets the same band whatever its history (deterministic subsets after undo/redo).
		return raw if raw >= 0 and _band(effective_m, radius, 1.0 - hysteresis * 0.5) >= 0 else -1
	var cur := current
	var coarser := raw < 0 or raw > cur
	var shifted := _band(effective_m, radius, 1.0 + hysteresis * 0.5 if coarser else 1.0 - hysteresis * 0.5)
	if coarser:
		return current if shifted >= 0 and shifted <= cur else shifted
	var s := GROUND_COVER_BANDS + 1 if shifted < 0 else shifted
	return current if s >= cur else shifted


static func ground_cover_factor(band: int) -> float:
	return 0.0 if band < 0 else pow(0.5, band)


static func _band(effective_m: float, radius: float, scale: float) -> int:
	if effective_m < radius * scale:
		return 0
	var k := 1
	while k <= GROUND_COVER_BANDS:
		if effective_m < radius * pow(sqrt(2.0), k) * scale:
			return k
		k += 1
	return -1


## Compatibility: drawn at all (any band) with hysteresis.
static func ground_cover_visible(effective_m: float, profile: Dictionary, visible_now: bool, hysteresis: float = 0.2) -> bool:
	return ground_cover_band(effective_m, profile, 0 if visible_now else -1, hysteresis) >= 0


static func _index(effective_m: float, limits: PackedFloat64Array, scale: float) -> int:
	var i := 0
	while i < limits.size() and effective_m >= limits[i] * scale:
		i += 1
	return i
