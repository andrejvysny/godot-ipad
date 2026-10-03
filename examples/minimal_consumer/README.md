# Minimal consumer

A Godot 4.7.2 project with no committed addons. `python3 scripts/make_minimal_consumer.py` builds the World Painter
archives, installs them into a temporary copy together with the AssetStudio archive and Terrain3D, imports it
headless, runs `cli.gd validate` and loads a fixture world through `WorldLoader`. See `docs/integration-consumer.md`.
