"""Schema 4 lock-level generation checks (ADR 0014 D6-D8): manifest lock hash, lock parse, reference rules,
dependency closure and the availability report. `gen` is a worldpoc_format.Generation (duck-typed to keep
the modules acyclic). Validators return lists of error strings and never raise."""
from __future__ import annotations

import hashlib
from typing import Any

from worldpoc_lockcheck import availability_report, check_dependencies, parse_lock
from worldpoc_v4 import referenced_bindings


def check_lock(gen: Any, trusted: dict[str, Any]) -> list[str]:
	"""Hash against the manifest's asset_lock block, then structure. Sets gen.lock and gen.bindings."""
	declared = gen.manifest.get("asset_lock")
	declared_sha = declared.get("sha256") if isinstance(declared, dict) else None
	actual = hashlib.sha256(gen.lock_bytes).hexdigest()
	errors: list[str] = []
	if declared_sha != actual and isinstance(declared_sha, str):
		errors.append("asset_lock sha256 %s does not match asset_locks.json %s" % (declared_sha, actual))
	lock, lock_errors = parse_lock(gen.lock_bytes, trusted)
	errors += lock_errors
	if lock is not None:
		gen.lock = lock
		gen.bindings = {b["binding_id"]: b for b in lock["bindings"]}
	return errors


def check_lock_references(gen: Any, trusted: dict[str, Any]) -> list[str]:
	"""Every binding is referenced by an object or scatter instance; dependencies equal the closure.
	Fills gen.availability (informational, never an error)."""
	referenced = referenced_bindings(gen.records, gen.scatter)
	errors = ["binding %s is not referenced by any object record or scatter instance" % bid
		for bid in sorted(set(gen.bindings) - referenced)]
	errors += check_dependencies(gen.lock, referenced)
	gen.availability = availability_report(gen.lock, trusted)
	return errors
