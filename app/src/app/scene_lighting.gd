class_name SceneLighting
extends RefCounted
## Sun and background environment of the editor scene: one fixed light, no shadows, no post effects (spec §13.1).


## Adds the lighting nodes to `parent` and returns the sun.
static func build(parent: Node) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.shadow_enabled = false
	parent.add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.18, 0.27, 0.34)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color.WHITE
	settings.ambient_light_energy = 0.5
	settings.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	settings.glow_enabled = false
	settings.ssao_enabled = false
	settings.ssil_enabled = false
	settings.ssr_enabled = false
	settings.sdfgi_enabled = false
	settings.fog_enabled = false
	settings.volumetric_fog_enabled = false
	environment.environment = settings
	parent.add_child(environment)
	return light
