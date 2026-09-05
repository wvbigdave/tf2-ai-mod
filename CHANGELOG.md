# Changelog

Versioning rule: **every update bumps the version**. Patch versions go up to
`.9`, then the minor bumps: `1.3.9 → 1.4.0` (never `1.3.10`).

## 1.3.4 (2026-09-05)
- Master **AI: ON/OFF** automation toggle on the main AI Builder menu — gates
  ALL autonomous work (build loop, line management, coverage expansion,
  corridor upgrades); persists in save; manual interface buttons still work
  while off; IPC payloads can't silently re-enable automation.
- Version bump catch-up for the four batches below (1.3.1 → 1.3.3 shipped
  without version bumps).

## 1.3.3 (2026-09-05)
- `line_manager.lua`: hardened remaining direct `getLine()` index sites
  (discoverCargoType, createNewLine, getSourceStationForTruckStop,
  setupBusLine) against stale/deleted lines.

## 1.3.2 (2026-09-05)
- Vehicle panel "Show more" nil-line crash fixed:
  `util.getComponent` now returns nil for nil/nonexistent entities instead of
  raising a sol error; `getLineReport` returns nil for deleted lines; vehicle
  panel shows "Select a line" instead of erroring; combobox/table refresh
  skip deleted lines.

## 1.3.1 (2026-09-05)
- Minimap crash fixed: `circleScale`/`minRadius`/`maxRadius` defined (were
  missing upstream in every fork lineage).
- Stale-edge guard in `getRouteInfoFromEdges` (nil `tnEdge` during bus line
  setup), plus nil-safe callers.
- **Funds gate**: user-initiated interface builds now check cash first and
  show "Not enough funds to reliably create the …" instead of building
  half-finished systems that error mid-way.

## 1.3.0 (2026-09-04)
- Initial deployment baseline (AI_Optimizer_1): 4x-once speed, cash-only
  1M-reserve budget, no loans, double-track default, community crash fixes.
