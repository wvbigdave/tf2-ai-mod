# 🚆 TF2 AI Builder — Transport Fever 2 Autonomous Transport Mod

> **Build whole transport empires in Transport Fever 2 — automatically.**
> The AI Builder plans, builds, and manages road, rail, bus, ship, and air
> networks for you, controlled from a built-in panel **or** an external agent
> over a file-based IPC bridge.

<div align="center">

![TF2](https://img.shields.io/badge/Game-Transport%20Fever%202-4f8c3c) ![Lua](https://img.shields.io/badge/Lua-5.3-2c2d72) ![Version](https://img.shields.io/badge/Version-1.3.4-blue) ![Status](https://img.shields.io/badge/Status-Active-brightgreen)

</div>

---

## ✨ Features

- 🏗️ **Autonomous building** — evaluates the best new connection (road/rail/water/air) and builds it, buys vehicles, and assigns them to lines
- 🚌 **Bus network builder** — creates bus stops and inter-city bus lines in any town
- 🚛 **Cargo logistics** — completes supply chains (raw → processor → factory → town)
- 🚄 **Rail corridors** — double-track enabled by default for cargo and passenger
- 📈 **ROI-driven upgrades** — yearly sweep upgrades the busiest lines/corridors first
- 💰 **Cash-only budgeting** — the AI never takes loans; it keeps a **1,000,000** cash reserve and only spends what it can reliably afford
- 🖥️ **In-game panel** — town table, line manager, upgrades panel, straighten tool, minimap
- 🔌 **File IPC bridge** — an external agent (e.g. Hermes) can query state and send build commands via `/tmp/tf2_cmd.json`

---

## ⚡ Quick Start

### 1. Install the mod

Copy the mod folder into your TF2 mods directory:

| OS | Path |
|----|------|
| Linux (Proton) | `<Steam>/steamapps/common/Transport Fever 2/mods/AI_Optimizer_1/` |
| Windows | `%APPDATA%\Transport Fever 2\mods\AI_Optimizer_1\` |
| macOS | `~/Library/Application Support/Transport Fever 2/mods/AI_Optimizer_1/` |

> ⚠️ The **folder name** (`AI_Optimizer_1`) is arbitrary, but the **game script file name** must be `ai_builder_script.lua` — saves bind to the script by file name.

### 2. Enable it in-game

1. Start Transport Fever 2
2. **Mod Manager** → enable the mod
3. Load a save **bound** to the script (created with the mod enabled), or start a new game with it enabled
4. The **AI Builder panel** appears in-game. Use the tabs to build bus networks, roads, rails, etc.

### 3. Verify it loaded

Check the game log for the mod. Or, if using the IPC bridge:

```bash
echo '{"id":"test","cmd":"ping","ts":"0"}' > /tmp/tf2_cmd.json
cat /tmp/tf2_resp.json   # → {"id":"test","status":"ok","data":"pong"}
```

---

## 💡 How It Works

### Autonomous mode

Enable **Full Management** from the AI Builder panel (or via IPC `enable_auto_build`). Every ~30 game-time units the mod:

1. Checks existing lines (no-path vehicles, capacity, upgrades)
2. Expands bus/cargo coverage in towns
3. Evaluates the **best new connection** by score (distance, gradient, terrain, existing stations, line rate, cargo bonus)
4. Builds it, buys vehicles, and starts the line

### Carrier selection (why you might only see trucks)

The mod picks **road** vs **rail** per connection using these rules:

- **Short routes** (< `maximumTruckDistance`, e.g. 2000–4000 early game) → trucks
- **Long routes** (> `minimumCargoTrainDistance`) → trains
- Towns beyond `maximumTruckDistance` → rail, but **grain** short-hops stay on trucks
- After a failed road attempt, it retries as rail

So in the early game with close industries, you will mostly see **truck lines** — that's expected behavior, not a bug. Rails show up as the map grows and routes get longer.

### 💰 Budget & loans (v1.3.0 behavior)

- The AI **never borrows money**. It only spends cash on hand.
- A **1,000,000 reserve** is always kept — the AI stops building when balance − reserve is too low for the next project.
- If you ask the interface to build something (bus network, rail connection, etc.) and there isn't enough cash to reliably complete it, the mod shows a clear **"Not enough funds…"** message in the panel and **does nothing** — no half-finished builds.

---

## 🛡️ Crash-Fix History

| Fix | File | What it prevents |
|-----|------|------------------|
| `circleScale` / `minRadius` / `maxRadius` defined | `ai_builder_minimap.lua` | Crash opening the minimap ("attempt to perform arithmetic on global 'circleScale'") |
| Stale-edge guards | `ai_builder_pathfinding_util.lua` | Crash when a path references an edge removed by deconflict/double-track ("attempt to index local 'tnEdge'") |
| `getRouteLengthOfPath` nil guard | `ai_builder_pathfinding_util.lua` | Crash when route info can't be resolved after stale edges |
| Road-station double-terminal fix | `ai_builder_construction_util.lua` | Road stations never got a free terminal for double-terminal upgrades |
| `station` nil in road lines | `ai_builder_line_manager.lua` | Road lines crashed with nil station in `addDoubleTerminalsToLine` |
| Empty consist guard | `ai_builder_line_manager.lua` | Arithmetic on nil `totalCapacity` when no wagon matches cargo/era |
| `getNode` returns nil instead of hard error | `ai_builder_base_util.lua` | Stale-node races turned into stack dumps |
| `checkForTrackupgrades` typo | `ai_builder_route_builder.lua` | `succes` typo silently skipped follow-up work |
| `buildRoute` nil/removed node guard | `ai_builder_route_builder.lua` | "Could not find node" hard error from stale nodes |
| Funds pre-check on UI builds | `ai_builder_script.lua` | Interface now reports "not enough funds" and aborts cleanly |

---

## 🔌 IPC Protocol

The mod communicates via two JSON files:

| File | Direction | Description |
|------|-----------|-------------|
| `/tmp/tf2_cmd.json` | External → Game | Commands to execute |
| `/tmp/tf2_resp.json` | Game → External | Command responses |

```bash
# Example: query game state
echo '{"id":"abc123","cmd":"query_game_state","ts":"0"}' > /tmp/tf2_cmd.json
cat /tmp/tf2_resp.json
```

### ⚠️ Critical: all JSON values must be **strings**

TF2's Lua JSON parser breaks on native numbers/booleans:

```json
// CORRECT
{"year": "1855", "money": "2500000", "paused": "false"}

// INCORRECT — will break!
{"year": 1855, "money": 2500000, "paused": false}
```

See [IPC_PROTOCOL.md](IPC_PROTOCOL.md) for the full command surface.

---

## 🗂️ Project Structure

```
tf2-ai-mod/
├── mod.lua                 # Mod manifest
├── res/
│   ├── scripts/            # Lua implementation (ai_builder_*.lua, simple_ipc.lua)
│   ├── config/
│   │   ├── game_script/    # ai_builder_script.lua (entry, event dispatcher)
│   │   ├── style_sheet/    # UI styles (incl. minimap styles)
│   │   └── construction_repository/
│   ├── construction/       # Custom interchange/track constructions
│   └── textures/           # UI textures
├── scripts/                # Helper scripts (install/restart — macOS notes)
├── docs/                   # Design docs, strategy references
└── IPC_PROTOCOL.md         # IPC specification
```

---

## 🐛 Debugging

| What | Where |
|------|-------|
| Game log | `<Steam userdata>/1066780/local/crash_dump/stdout.txt` |
| IPC debug log | `/tmp/tf2_simple_ipc.log` |
| Build debug | `/tmp/tf2_build_debug.log` |
| Water build debug | `/tmp/tf2_water_build.log` |
| Event log | `/tmp/tf2_events.log` |

---

## 📚 Related

- **tf2-ralphy** — Python MCP server for Claude Code integration
- **Hermes skills** — `tf2-ai-builder`, `tf2-modding`, `tf2-remote-game-control` for ops workflows

---

## 📄 License

MIT
