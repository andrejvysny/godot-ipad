---
name: godot-ipad-schema4-gotchas
description: Durable gotchas for godot-ipad schema 4 / test running
metadata:
  type: project
---
- Run Godot test filters as `--filter=file::` ; runner deletes user://test_scratch after every test, so never run two Godot test runs concurrently outside `scripts/dev.py test` (it isolates user dir).
- dev.py sandboxes app/ at build/test_sandboxes/<n>/app: tests reading contracts/ must use tests/support/contract_files.gd.
- test_input_lab pollutes real user://input_lab across direct runs (delete active_world.txt); dev.py is isolated.
- Stray empty files under addons/world_painter break BenchSourceIdentity (HashingContext len==0).
- macOS sed needs `sed -i ''`; a bad `sed -i` created a stray file once.
