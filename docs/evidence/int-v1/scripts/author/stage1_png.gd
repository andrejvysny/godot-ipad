extends SceneTree
func _png(path: String, base: Color, alt: Color, alpha_hole: bool) -> void:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var c := base if ((x / 8 + y / 8) % 2 == 0) else alt
			if alpha_hole and ((x - 16) * (x - 16) + (y - 16) * (y - 16)) > 200:
				c.a = 0.0
			img.set_pixel(x, y, c)
	img.save_png(path)
func _init() -> void:
	DirAccess.make_dir_recursive_absolute("res://textures")
	_png("res://textures/bark.png", Color(0.35, 0.22, 0.12, 1), Color(0.28, 0.17, 0.09, 1), false)
	_png("res://textures/leaf.png", Color(0.2, 0.55, 0.15, 1), Color(0.15, 0.45, 0.1, 1), true)
	quit()
