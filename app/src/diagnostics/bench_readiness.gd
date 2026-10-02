class_name BenchReadiness
extends RefCounted
## Admission diagnostics separate runnable work from held work in the terrain-only view.


static func capture(session: EditorSession) -> Dictionary:
	var render := session.render_state()
	var masked := bool(render.view.status().objects_view_suppressed)
	var cache := render.cache.stats()
	var world := session.presenter.render_world()
	var scatter := session.layers.scatter._engine
	var hlod_enabled := bool(render.comparison_flags().hlod_enabled)
	var missing_grid := hlod_enabled and (render.overview == null or render.overview._groups.is_empty()
			or render.overview._groups[0].is_empty())
	return {"objects": not masked and session.presenter.has_pending_work(),
		"terrain": session.terrain.has_pending_uploads(), "scatter": not masked and session.layers.scatter.has_pending_work(),
		"overview": not masked and (missing_grid or (render.overview != null and render.overview.has_pending_work())),
		"overview_work": {"enabled": hlod_enabled, "missing_grid": missing_grid},
		"cache": not masked and (int(cache.queued) > 0 or int(cache.loading) > 0), "view_suppressed": masked,
		"object_work": {"queued_batches": world._queue.size(), "awaiting_assets": world._res.awaiting.size(),
			"dirty_batches": world._dirty.size(), "classification_pending": world._size_visibility.busy() if world._size_policy_enabled else world._lod.busy(),
			"rechecks": world._recheck.size()},
		"scatter_work": {"queued_cells": scatter.pending_builds(), "roles_due": scatter._roles_due,
			"roles_retry": scatter._roles_retry, "role_scan": scatter._role_scan.size(), "view_force": scatter._view_force,
			"awaiting_assets": scatter.builder.res.awaiting.size()}}
