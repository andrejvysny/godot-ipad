# 0003 — Exact float64 values in objects.json

Status: accepted.

## Context

Probe on Godot 4.7.2: `JSON.stringify(0.9659258262890683, "", true, true)` writes the shortest
round-trip decimal, but `JSON.parse_string` of that text returns a double that differs by one ulp.
`str_to_var` behaves the same way. Godot's decimal-to-double conversion is not correctly rounded
for all 16–17 digit inputs, while Python's is.

Consequence: object transforms saved to `objects.json` would not reload bit-identically, so the
authored content hash would change after save → reopen, and iPad → Mac could differ from Python.

## Decision

Every object record keeps its readable decimal fields and adds an `f64le` block holding each float64
as 16 hex digits of its little-endian IEEE-754 bytes (`struct.pack('<d', v).hex()` in Python,
`PackedByteArray.encode_double` + `hex_encode()` in Godot). Loaders use the bits and reject records
whose bits are missing, non-finite, or disagree with the decimal by more than `1e-9·max(1,|v|)`.

The catalog hash avoids the problem differently: it hashes raw file bytes, never parsed values
(docs/world-format.md §6).

## Consequences

Round trips are bit-exact in both languages; the authored hash is stable across save, reopen,
export, and the Mac consumer. The file is slightly larger and slightly redundant; the redundancy is
checked, so it cannot silently diverge.
