# 0011 — Finger operates UI

Status: accepted 2026-10-01 (user decision). Supersedes the "fingers never operate UI" rule of
`docs/input-contract.md` and ADR 0007 (Library drops stay Pencil-only).

## Decision

- A finger can operate every UI control (buttons, tabs, menus, sliders, scrub fields, inspector) and
  arm a Library tile by tap. Viewport editing stays Pencil-only; fingers in the viewport only
  navigate; Library drag-to-place stays Pencil-only (a finger drag on a tile places nothing).
- Router state `FINGER_UI`: a finger beginning over interface becomes a UI owner only when the router
  is IDLE (a modal is allowed), no Pencil is down, at least `input.finger_ui_guard_s` has passed since
  the last Pencil contact ended, and the contact is not palm-sized. Otherwise it is inert, with a
  `finger_ui_guarded` / `finger_ui_palm` diagnostic.
- A Pencil beginning during a finger UI press cancels it (`ui_cancel`, `pencil_took_ownership`).
- `ui_press` carries `source` (`finger` / `pencil`); `InputSystem.ui_press_is_pencil()` exposes it.
- Native records gain field 14 `major_radius` (`UITouch.majorRadius`, points, NaN when unknown); stride 15.
  The decoder still accepts stride 14.

## Palm guards

Initial values: `finger_ui_guard_s = 0.3`, `palm_radius_pt = 30.0` (config `input`). Both are
guesses and need device calibration.

## Evidence

Desktop tests only. Device results: NOT RUN (`docs/device-test-checklist-v2.md` V2-UI-04, 04b, 04c).
