extends TexturePreviewTestCase


func test_overview_suspension_retains_anchor_and_resumes_request() -> void:
	var ctrl := _make(_mixed_doc())
	assert_true(ctrl.enable_at(Vector3(5.0, 0.0, 7.0), 12.0).ok)
	await _drive(ctrl)
	var before := ctrl.status()
	ctrl.set_view_suspended(true)
	assert_eq(ctrl.state(), TexturePreviewController.SUSPENDED)
	assert_eq(ctrl.status().center, before.center)
	assert_eq(ctrl.status().radius, before.radius)
	assert_false(bool(_adapter.preview_uniforms().preview_enabled))
	for i in 10:
		ctrl.service(2.0)
		await tree.process_frame
	ctrl.set_view_suspended(false)
	for i in TIMEOUT_FRAMES:
		ctrl.service(2.0)
		if ctrl.state() in [TexturePreviewController.ACTIVE, TexturePreviewController.LIMITED]:
			break
		await tree.process_frame
	assert_true(ctrl.state() in [TexturePreviewController.ACTIVE, TexturePreviewController.LIMITED])
	assert_eq(ctrl.status().center, before.center)
	assert_eq(ctrl.status().radius, before.radius)
	ctrl.set_view_suspended(true)
	ctrl.disable("user")
	await tree.process_frame
	ctrl.service(2.0)
	assert_eq(ctrl.state(), TexturePreviewController.OFF)
	ctrl.set_view_suspended(false)
	ctrl.service(2.0)
	assert_eq(ctrl.state(), TexturePreviewController.OFF)


func test_overview_reentry_before_resume_preserves_request() -> void:
	var ctrl := _make(_mixed_doc())
	assert_true(ctrl.enable_at(Vector3(5.0, 0.0, 7.0), 12.0).ok)
	await _drive(ctrl)
	ctrl.set_view_suspended(true)
	ctrl.set_view_suspended(false)
	ctrl.set_view_suspended(true)
	assert_eq(ctrl.state(), TexturePreviewController.SUSPENDED)
	ctrl.set_view_suspended(false)
	for i in TIMEOUT_FRAMES:
		ctrl.service(2.0)
		if ctrl.state() in [TexturePreviewController.ACTIVE, TexturePreviewController.LIMITED]:
			break
		await tree.process_frame
	assert_true(ctrl.state() in [TexturePreviewController.ACTIVE, TexturePreviewController.LIMITED])
	assert_eq(ctrl.status().center, Vector3(5.0, 0.0, 7.0))
	assert_eq(ctrl.status().radius, 12.0)
