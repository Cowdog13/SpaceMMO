# SpaceMMO

A server-authoritative, tick-based space MMO made with **Godot 4.3+** (GDScript, no assets needed).
The solar system sits on a hex grid. Planets orbit the Sun, there's an asteroid belt between
Mars and Jupiter, mercenaries roam the lanes, and PvP is open everywhere except planetary safe zones.

## Quick start

1. Install [Godot 4.3 or newer](https://godotengine.org/download) (standard build, not .NET).
2. Open this folder in the Godot editor and press **Play** (F5). The login screen appears.
3. Click **Start a local server on this PC**, type a pilot name and password, then click **Connect**.
   A new name creates an account automatically.

To play with friends, one person runs the server and the others enter that machine's IP address.

## Running a dedicated server

The server is the same project started with `--server` (or any `--headless` run). It uses **UDP port 7777**.

```bash
GODOT=/path/to/godot ./run_server.sh
```

Windows: set `GODOT` to your `Godot_v4.x_win64_console.exe`, then run `run_server.bat`.

Options (put them after `--` when you call Godot directly):

| Flag | Default | Meaning |
|---|---|---|
| `--port N` | 7777 | UDP port to listen on |
| `--data DIR` | `user://server_data` (`./server_data` from the scripts) | Where accounts and the market are saved |
| `--max-players N` | 128 | Connection limit |
| `--dev` | off | Enables cheat chat commands: `/tp q r`, `/tp venus`, `/give item qty`, `/credits n`, `/xp n` |

### Cheap VPS (Docker)

```bash
docker build -t spacemmo .
```

```bash
docker run -d --name spacemmo --restart unless-stopped -p 7777:7777/udp -v spacemmo_data:/data spacemmo
```

Open UDP 7777 in the host's firewall. On a 1 vCPU VPS the simulation uses about 8 ms of each
167 ms tick with ~280 units, and each player costs roughly 10–20 KB/s of upload.
For a home PC, forward **UDP** 7777 on your router to that machine.

You can also export a headless build: Project → Export → Linux, with the export mode
"Dedicated Server", then run `./SpaceMMO.x86_64 --headless -- --server`.

## Building the game for friends

`export_presets.cfg` has **Windows** and **Linux** presets. Each one builds a single self-contained
executable with the game data embedded. Install the Godot 4.3 export templates (Editor → Manage
Export Templates) and use Project → Export, or build from the command line:

```bash
godot --headless --path . --export-release "Windows" export/windows/SpaceMMO.exe
```

```bash
godot --headless --path . --export-release "Linux" export/linux/SpaceMMO.x86_64
```

The Windows build also creates `SpaceMMO.console.exe`. Use it to run a server in a console window
with visible logs: `SpaceMMO.console.exe --headless -- --server`.

## Controls

| Input | Action |
|---|---|
| Right-click hex | Move the selected units there (pathfinding goes around the Sun, planets and asteroids) |
| Right-click enemy | Target it; selected drones attack it |
| Left-click enemy | Set it as your target |
| Left-click / drag a box | Select your ship and drones (Shift adds to the selection) |
| `1`–`9`, `0` | Activate a system or use a consumable (aimed at your target) |
| Right-click a system button | Toggle auto-fire for that weapon |
| `Tab` | Target nearest (mercenaries first) |
| `F` | Dock or undock (when near a planet) |
| `M` | System map; click it to set a long-distance course |
| `S` / `R` / `A` | Stop / recall drones / select all your units |
| `Space`, middle-drag, wheel | Re-centre camera, pan, zoom |
| `Enter` | Chat (`/who`, `/where`) |
| `H` | Help overlay |

## Game rules implemented

- **Ticks**: 6 per second. Every action you request resolves on the next tick.
  An item with `channel` resolves on the tick after its channel finishes. Moving cancels a channel.
  An item with `delay` or a projectile travel time resolves after that delay.
- **Movement**: one unit per hex. The fastest a ship can move is 1 hex every 15 ticks (2.5 s); heavier
  hulls are slower. After a move, the ship's front points away from the hex it left. If two units try
  to enter the same hex on the same tick, both moves are cancelled.
- **Hulls and ports**: the hull sets hull points, energy, cargo, speed and the ports. Each port holds
  one item. A weapon fires only at targets inside its port's arc (for example the front port covers 90°).
  Body ports take shields, energy items and mods. Your arcs are drawn around your ship, and an arc
  brightens when your target is inside it.
- **Item types**: weapon, shield, mod, energy, consumable (plus hull). Activating systems costs energy.
  With no energy you can still move but can't activate systems. Consumables cost no energy, so an
  Energy Cell can get you going again.
- **Drones**: a Drone Bay mod launches combat drones. They follow you and defend you, and you can
  select them to move them or order attacks.
- **World**: a hex map 1001 hexes across (radius 500). The Sun is at the centre, the 8 planets orbit
  at their real period ratios (one Earth year = 4 real hours, set in `World.YEAR_SECONDS`), and
  there's an asteroid belt between Mars and Jupiter.
- **Zones**: new players start at Earth (threat T1). Venus is T2 and Mercury T3, so going sunward is the
  low-level path. The asteroid belt is T7, and the outer system runs from T8 to T10.
- **Stations**: dock within 4 hexes of a planet's surface. Docking fully repairs your ship and refills
  energy. At a station you can buy and sell with the shop (each planet stocks different items), equip
  items and swap hulls in the hangar, trade on the player market (you're paid even while offline),
  and set your home station.
- **Mercenaries**: they wander their orbital band, chase players who come near, stay out of safe zones,
  and drop credits plus loot crates. Fly next to a crate to collect it; the top damage dealer gets
  20 s of priority. Kills give XP, which raises your level and unlocks items.
- **PvP**: open everywhere except safe zones. Inside a safe zone nobody can deal or take damage. When
  you die you drop your cargo and 10% of your credits, then respawn docked at your home station.
  Equipped items are kept.
- **Persistence**: accounts (salted SHA-256 password hash), ships, cargo and the market are stored as
  JSON in the data directory, saved every 60 s, on dock and death, and on logout.

## Project layout

```
scripts/main.gd               entry point: picks client / server / bot from command-line args
scripts/net/net.gd            autoload "Net": every RPC (c_login, c_cmd, s_state, s_msg)
scripts/shared/hex.gd         axial hex math, arcs, rings
scripts/shared/world_def.gd   Sun, planet orbits, asteroid belt, safe zones, threat zones
scripts/shared/items_db.gd    ALL content: hulls, items, shops, merc loadouts, loot table
scripts/server/server.gd      authoritative simulation, accounts, stations, AI, snapshots
scripts/server/entity.gd      ship / merc / drone state and stat calculation
scripts/server/pathfinder.gd  bounded A*
scripts/server/persistence.gd JSON saves
scripts/client/client.gd      connection, replicated state, input
scripts/client/world_view.gd  procedural rendering of the system, units and effects
scripts/client/ui.gd          login, HUD, systems bar, chat, station window, system map
scripts/client/bot.gd         headless test bot (load testing / scripted tests)
```

### Adding content

- **Items**: add an entry to `ITEMS` in `items_db.gd`. Passive bonuses go in `stats`. An activatable
  system goes in `active`, with `effect` set to `damage`, `restore_shield`, `restore_energy`, `heal`
  or `spawn_drone`, plus `energy`, `cooldown`, `channel`, `delay`, `range` and `projectile_speed`.
  Then add the item to a planet's `SHOPS` list or to the `LOOT_TABLE`.
- **New effect types**: extend `_validate_effect` and `_apply_effect` in `server.gd`.
- **Hulls**: list their `ports` with `kind` (`weapon` or `body`), plus `dir` (degrees from the front)
  and `arc` for weapon ports.
- **Enemies**: add to `MERC_TEMPLATES` (`min_tier` decides where they appear) and tune `ZONES`
  in `world_def.gd`.

### Testing with bots

```bash
godot --headless --path . -- --bot Tester --seconds 60 --tp -100,0
```

`--steps "buy item=laser_mk1;undock;dump"` runs scripted commands (see `bot.gd`). The `--tp` flag and
the `/tp` style chat commands only work when the server was started with `--dev`.

## Known limitations / next steps

- Logins are sent unencrypted (ENet without DTLS). Fine for friends and testing; add DTLS before
  a public launch.
- Logging out in space removes your ship immediately, so a logout timer is needed to stop players
  escaping combat that way.
- Content is placeholder: a handful of items, 4 hulls and 4 mercenary types, all with procedural graphics.
- Snapshots are sent every tick for everything within 42 hexes. Interest management and
  delta compression would be the next step for large player counts.
