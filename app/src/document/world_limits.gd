class_name WorldLimits
extends RefCounted
## Centralized per-schema admission limits (docs/world-format.md §11.3). Python mirrors the
## numbers in scripts/worldpoc_constants.py; scripts/tests/test_limits_parity.py parses this
## file, so keep every value a plain product of integers (`4 * 1024 * 1024`).

const SCHEMA_2 := {
	"max_regions": 4,
	"max_objects": 2000,
	"max_objects_bytes": 4 * 1024 * 1024,
	"max_scatter_instances": 20000,
	"max_scatter_bytes": 512 * 1024,
	"max_paths_bytes": 640 * 1024,
	"max_manifest_bytes": 64 * 1024,
	"max_total_bytes": 12 * 1024 * 1024,
	"max_archive_bytes": 20 * 1024 * 1024,
	"max_entries": 20,
}

const SCHEMA_3 := {
	"max_regions": 64,
	"max_objects": 50000,
	"max_objects_bytes": 128 * 1024 * 1024,
	"max_scatter_instances": 100000,
	"max_scatter_bytes": 4 * 1024 * 1024,
	"max_paths_bytes": 640 * 1024,
	"max_manifest_bytes": 256 * 1024,
	"max_total_bytes": 256 * 1024 * 1024,
	"max_archive_bytes": 264 * 1024 * 1024,
	"max_entries": 197,
}


## Limits of a schema; an empty dictionary for an unsupported schema (callers check first).
static func for_schema(schema: int) -> Dictionary:
	if schema == WorldConstants.SCHEMA_VERSION:
		return SCHEMA_2.duplicate()
	if schema == WorldConstants.SCHEMA_VERSION_LAYOUT:
		return SCHEMA_3.duplicate()
	return {}


## Package inspection runs before the manifest is read, so it applies the largest schema.
static func zip_envelope() -> Dictionary:
	return SCHEMA_3.duplicate()
