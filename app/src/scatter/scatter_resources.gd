class_name ScatterResources
extends RenderWorldResources
## RenderWorldResources for the scatter layer: its own owner ("scatter:<epoch>") and its own generation token
## so an object-world epoch change (token "world_epoch") never cancels scatter requests, nor the reverse.


func owner() -> String:
	return "scatter:%d" % epoch


func tokens() -> Dictionary:
	return {"scatter_epoch": epoch}


func next_epoch() -> void:
	cache.cancel_generation("scatter_epoch", epoch)
	cache.release(owner())
	epoch += 1
	_requested.clear()
	awaiting.clear()
