class_name RenderVisibilityDecision
extends RefCounted
## Pure size eligibility; selected and active geometry bypass size thresholds at the caller.


static func evaluate(measurement: Dictionary, visible_now: bool = true, decorative: bool = false,
		settings: Dictionary = {}, forced: bool = false) -> Dictionary:
	if forced:
		return {"visible": true, "reason": "forced"}
	if not bool(measurement.get("valid", false)) or bool(measurement.get("conservative", true)):
		return {"visible": true, "reason": "conservative"}
	if bool(measurement.get("behind", false)):
		return {"visible": false, "reason": "behind"}
	var visible := LodPolicy.size_visible(float(measurement.get("reference_px", INF)),
			visible_now, decorative, settings)
	return {"visible": visible, "reason": "size_visible" if visible else "size_hidden"}
