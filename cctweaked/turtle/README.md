# Turtle quarry and wireless dashboard

`chunk_dig.lua` digs a square, measured in chunks, from the layer below the turtle down to bedrock. It works out of a fixed base at its starting position. Cargo goes into a stationary output barrel there, and coal blocks come from a stationary fuel inventory. When cargo needs unloading or fuel runs low, the turtle goes home along a route through blocks it has already cleared. After servicing, it returns to the exact cell and heading it left and carries on.

`turtle_wireless_dash.lua` shows every quarry turtle broadcasting on `turtle_quarry_v1`. You don't configure a turtle ID.

The turtle saves an active job to its own filesystem. It stops when its chunk unloads and can continue the same job when the chunk loads and the computer boots. A chunk loader is not required. An interrupted action whose outcome cannot be established safely pauses for verification instead of risking a wrong move.

## Base placement and configuration

Home is the turtle's original cell and facing when you start the program. The quarry extends forward and to the right of home. Digging starts one block below home, so the home level (and anything beside the turtle) is never dug.

Two settings at the top of `chunk_dig.lua` say where the base inventories are, relative to the turtle's starting facing:

```lua
local OUTPUT_SIDE = "back"   -- cargo barrel/chest
local FUEL_SIDE   = "top"    -- coal-block inventory
```

- These are only the defaults (output behind the turtle, fuel above it). Edit both lines to match where your barrel and fuel inventory actually are.
- Allowed values are `front`, `back`, `left`, `right` and `top`. `bottom` is rejected because the space under home is the quarry shaft.
- The two sides must be different, because output and fuel are separate inventories.
- `front` works for storage. A block in front of home sits at the home level, which the quarry never digs; the first dug layer is one below.
- At startup both inventories are checked. If either is missing, the turtle stops at home with an error before it moves.
- The turtle never digs a block at the home level. The one exception is a gravity block (sand or gravel) that has fallen into the home cell itself, and it is never dug if it looks like storage. Storage blocks are never dug or replaced.

Other settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `SAFETY_MARGIN` | 32 | Fuel kept beyond the exact cost of the route home |
| `MIN_PROGRESS` | 64 | Minimum mining moves a fuel trip must allow before it leaves home |
| `RETRY_SECONDS` | 5 | Delay between retries while waiting for output space, fuel, or a blocked route |

## Download and run

On a mining turtle with a pickaxe and, optionally, a wireless or Ender modem upgrade, download to the root of its filesystem. If the old `chunk_dig` is already installed, do not replace it while that job is running; see [One-time migration](#one-time-migration).

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/chunk_dig.lua /chunk_dig
chunk_dig 1 "Mining Quarry 01"
```

Edit `OUTPUT_SIDE` and `FUEL_SIDE` before running the second command. Start only while the turtle is at its base, facing the intended quarry. The first argument is the side length in chunks: `1` = 16×16, `2` = 32×32, `3` = 48×48 blocks. The optional second argument sets the job name; without it the turtle label is used. A new job refuses to replace existing state, even if the job is complete. Align the turtle to chunk boundaries yourself if needed, and note the home block's world coordinates and compass facing so you can verify a pending turn later even without GPS.

Optional GPS-anchored start, if the turtle is actually facing east:

```text
chunk_dig 1 "Mining Quarry 01" east
```

Use `north`, `east`, `south` or `west` to match the turtle's starting facing. Verify this yourself in Minecraft; the argument does not turn the turtle. This requires an initial GPS fix and saves the original world XYZ and cardinal direction. It makes interrupted moves recoverable even with unlimited fuel and provides world coordinates in manual recovery instructions. The [CC:Tweaked GPS setup guide](https://tweaked.cc/guide/gps_setup.html) explains the modem and host setup. GPS hosts need to be reachable and loaded when used; they are optional and are not chunk loaders for the quarry.

On the dashboard computer, with a wireless or Ender modem and optionally a monitor:

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/turtle_wireless_dash.lua turtle_wireless_dash
turtle_wireless_dash "turtle_wireless_dash"
```

The optional argument sets the dashboard hostname. Left/right arrows, the mouse wheel, or a monitor touch change pages. Only rows that changed are redrawn.

A `/startup.lua` for the dashboard computer only:

```lua
shell.execute("/turtle_wireless_dash", "turtle_wireless_dash")
```

## Enable automatic resume on the turtle

If there is no existing `/startup.lua` or conflicting startup setup, download the provided turtle startup script:

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/startup.lua /startup.lua
```

If you already have startup logic, **keep it**. Back it up, then add this one line after the other setup. The quarry runs in the foreground while active, so put the line last if the rest of startup needs to finish. Do not replace unrelated logic or put the new-job command in startup.

```lua
shell.execute("/chunk_dig", "auto")
```

`auto` runs only a compatible active job. With no job or a completed job it returns immediately. With corrupt state or unresolved motion it reports `recovery_required` and returns without mining or starting another job. The boot hook can run only when the computer boots; if your server reloads the turtle without booting its computer, turn it on or use `chunk_dig resume`. Don't run another turtle-control program concurrently.

## Slot behaviour

- Slot 1 stays selected while mining and idle. Inventory work temporarily selects other slots for unloading, compacting partial stacks, and burning carried fuel. Slot 1 is selected again afterwards, including after errors.
- All 16 slots hold cargo. No slot is reserved, and no portable chest is used.
- Before every dig the turtle makes sure it has an empty slot. If none is free, it first merges partial stacks of the same item. If every slot is still occupied, it goes home with the status detail `no empty cargo slot`.
- Base refuelling uses slot 1. The turtle unloads everything first, so slot 1 is empty. It then pulls one coal block from the fuel inventory into slot 1 and calls `turtle.refuel` on it, repeating as needed. Selecting slot 1 alone does not refuel a turtle; the script always calls `turtle.refuel` explicitly. Afterwards slot 1 is empty again and holds cargo.
- Fuel already in the inventory (for example mined coal) can be burned before making a trip just for fuel. The turtle selects that slot, burns one item at a time only until the fuel need is met, and reselects slot 1. Any remaining coal is not hoarded and is unloaded with the rest of the cargo.
- Anything you put in the turtle before starting is unloaded into the output barrel at startup. The exception is fuel burned to reach the starting fuel requirement.

## Fuel budgeting

There is no fixed low-fuel threshold. The turtle records a route home through cleared cells and keeps a fuel budget against it.

- **Home reserve.** Before every mining move the turtle requires fuel ≥ route-home cost + 2 + `SAFETY_MARGIN`. The route-home cost is an upper bound on the real route, so it includes vertical moves and detours around undiggable blocks. If fuel would fall below that, the turtle burns carried fuel first. If that isn't enough, it goes home to refuel. The dashboard shows this value as `reserve`.
- **Leaving home.** A refuel trip leaves only with fuel ≥ 2 × (route to the work position) + 2 × `MIN_PROGRESS` + `SAFETY_MARGIN`. That covers reaching the work position, doing useful work, and returning home. The first departure uses the same rule with a route length of 0.
- **Refuelling.** Coal blocks are burned one at a time until the requirement is met. The tank is then topped up as far as it will go without wasting fuel above the limit. Coal blocks are not stored in the inventory as spare fuel.
- **Fuel limit.** If the required round trip is larger than the turtle's fuel limit, the turtle stays home and stops with an error such as `round trip needs X fuel but the fuel limit is Y`.
- **Unlimited fuel.** On servers with fuel disabled, `unlimited` is handled: no fuel trips are made and the reserve shows 0.
- **No nested trips.** Travel home and back never triggers another unload or refuel trip, because the budget already covers it.

## Return, unload, refuel, resume

1. The turtle saves its exact cell, heading, and progress through the sweep.
2. It travels home along recorded cleared cells: inside the current layer to where it entered, then back up through each layer's recorded route. These routes include any up or down steps from detours, so the turtle never assumes a straight path is open. If gravel or sand has fallen into a cleared quarry cell, it is dug again. Anything else blocking the route makes the turtle wait and report `blocked`.
3. At home it unloads all 16 slots into the output barrel, including surplus coal. It then refuels from the fuel inventory if needed.
4. It returns along the same route in reverse and turns back to the saved heading. It checks that its position matches the saved one, then continues the same sweep. No cell is skipped or repeated, and it doesn't descend an extra layer.

## Waiting and error states

The turtle keeps broadcasting telemetry while waiting.

| Status | Meaning | What happens |
| --- | --- | --- |
| `waiting_output` | Output barrel full, missing, or a transfer failed. The detail says which. | Stays home with the remaining cargo and retries every `RETRY_SECONDS`. |
| `waiting_fuel` | Fuel inventory empty or missing, it holds non-fuel items, or not enough fuel was obtained. | Stays home and retries automatically when you restock. |
| `blocked` | A cleared route cell is occupied by something it may not dig, or a mob or entity won't move. | Retries every `RETRY_SECONDS`. |
| `error` | Base inventories missing at start, round trip too large for the fuel limit, or another execution error. | Does not continue mining. Fix the reported issue before resuming. |
| `stopped` | Terminated with Ctrl+T outside an uncertain motion. | Stops in place and retains the job. |
| `recovering` / `resumed` | Loading and checking the saved job / verification passed. | Re-enters the exact saved work or service step. |
| `recovery_required` | The saved state or physical pose cannot be trusted automatically. | No further quarry actions; read the turtle terminal before doing anything. |

Every move, dig, drop, suck, and refuel result is checked. Coordinates change only after a successful move. Items are never thrown into the world. A failed action is never reported as success.

Other statuses: `starting`, `mining`, `returning_to_unload`, `returning_to_refuel`, `unloading`, `refueling`, `resuming`, `returning_home`, `complete`.

## Mining and obstacles

- Each layer is swept in a serpentine pattern. When the turtle meets a block it may not dig, it routes around it within the layer.
- If undiggable blocks wall off part of a layer, it reaches that part by crossing the cleared layer above and digging down into it. This includes the uneven bedrock pockets near the bottom.
- Cells walled off on every side and from above are dug upward from the cleared cell below.
- Cells it cannot reach any way are skipped and counted in the log. The descent to the next layer is chosen from the cleared cell nearest home that has a diggable block below it.
- The job is complete when no cell in the current layer has anything diggable below it.
- `minecraft:bedrock` and all Allthemodium-family ores (`allthemodium:*ore*`) are never dug. Turtles cannot harvest those ores, so the quarry leaves them for you to mine by hand.
- On completion the turtle returns home and unloads the final cargo. It waits as `waiting_output` if the barrel is full. It then turns to its original heading, selects slot 1, and reports `complete`. It keeps broadcasting until you press Ctrl+T.
- The program does not remove liquids or block off lava.

## Dashboard

One block per turtle shows:

- name and computer ID, with the state in colour (shown as `OFFLINE` after 15 s without a packet)
- current fuel / fuel limit, the required home reserve, and the last fuel item burned
- job size, current layer and cells cleared in that layer, blocked cells, total cells and service trips
- cargo use across all 16 slots
- position relative to home (forward / up / right) and heading
- a status detail

GPS fixes are taken about every 15 seconds when a GPS network exists. If the turtle has moved since the last fix, or the fix is older than 30 s, it is shown as `STALE` rather than as the current position.

The protocol is still `turtle_quarry_v1`, version 1. The dash recognizes the three recovery states and shows **Position / heading not verified** until recovery establishes the pose. An older dash can still receive packets. Update both scripts for the new status display.

## Chunk loading

No force-loading is needed. Unloading pauses work, and startup tries to resume it when the turtle's chunk loads and the computer boots. The job does not run while its chunk is unloaded. If the turtle reaches an unloaded neighboring chunk, the movement is rejected by [CC:Tweaked's movement command](https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/mc-1.21.x/projects/common/src/main/java/dan200/computercraft/shared/turtle/core/TurtleMoveCommand.java). It waits and retries the same move, so a return to base can also wait until the chunks along the route load naturally.

## Recover manually

```text
chunk_dig status
chunk_dig resume
```

`status` prints the saved pose, phase, generation, and both candidate poses for any pending move or turn. `resume` never falls back to starting a new job. If anchored GPS is temporarily unavailable, restore it and retry `resume`.

If instructed to resolve a pending action, wait until the turtle is stationary. Check its **actual** position and facing in Minecraft without moving or turning it. With a GPS-anchored job the terminal prints both candidate world coordinates and compass directions; otherwise use the original home and forward/right directions to interpret the relative offsets. Heading `0` is original forward, `1` right, `2` back and `3` left.

```text
chunk_dig resolve 123 after
```

Use the displayed generation in place of `123`. Use `before` only if the turtle is in the before pose; use `after` only if it is in the after pose. This resumes immediately on acceptance; it does not move the turtle to the named pose. Do not guess or use this command if it matches neither candidate. If the state itself is corrupt or incompatible, preserve `/.chunk_dig` for diagnosis instead of deleting individual files or copying the older checkpoint over the newer one.

## What recovery does and does not prove

- **Checkpoints:** Two versioned, checksummed checkpoint files alternate under `/.chunk_dig`, with the previous committed copy retained. Writes are staged and read back before publication. An unfinished `.tmp` is not a checkpoint. A corrupt committed file stops recovery rather than rolling back blindly to a pose that might be stale.
- **Action journal:** Before every move or turn the script publishes the original pose, candidate next pose, fuel observation and checkpoint generation. It keeps that intent until the result is committed. The motion and the execution step that receives its result are recovered together, including a move into the next layer.
- **Moves:** An anchored job compares a fresh GPS fix with the two candidate positions. Without an anchor, an ordinary interruption with fuel enabled uses exactly one unit of fuel consumed versus no change. The [CC:Tweaked maintainer explains why ordinary chunk unload cannot split teleport and fuel deduction](https://github.com/cc-tweaked/CC-Tweaked/issues/1364); the [movement implementation](https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/mc-1.21.x/projects/common/src/main/java/dan200/computercraft/shared/turtle/core/TurtleMoveCommand.java) deducts one unit only after teleport succeeds. This inference assumes stock movement, no external fuel changes, and no independent world rollback. Unlimited fuel without GPS or an unexpected delta requires verification.
- **Turns:** GPS locates the turtle but does not report its facing. Stock turtle turns cost no fuel ([turtle API](https://tweaked.cc/module/turtle.html)). If power is lost after a turn is journaled but before its result is committed, the turtle stops for manual verification, even with GPS. It does not make a test move or assume a turn happened. An already-committed turn does not need this step.
- **Inventory:** On reboot the live inventory and fuel buffer determine what is left to unload or refuel. For example, a coal block pulled into slot 1 just before shutdown is there to burn on reboot, not a reason to pull another one. A partial unload continues from the slots that still contain cargo. Slot 1 is selected first on startup and restored after temporary selections.
- **Limits:** The turtle filesystem and Minecraft world are not one transaction (see the [CC:Tweaked persistence discussion](https://github.com/cc-tweaked/CC-Tweaked/issues/535)). Don't manually relocate or turn the turtle, change its fuel buffer while a motion is unresolved, or restore its files separately from the world. An arbitrary server crash, world rollback, copied files, or changed terrain can invalidate a checkpoint. Leave room on the turtle filesystem for two checkpoints plus a staged write; larger footprints and long detours use more space.

## Safely discard or archive a job

1. Stop the quarry with Ctrl+T if it is running, wait for movement to settle, and run `chunk_dig status`. Keep both checkpoint files and the journal together. If you need to recover the active job later, don't manually move, turn or refuel the turtle while its state is archived.
2. Rename the whole directory to an unused archive name, for example `move /.chunk_dig /.chunk_dig-archive-01`. With the active directory gone, boot will not resume it. Keep the archive until you are sure you no longer need it; do not restore just one checkpoint.
3. To start a different job, put the turtle at the intended base position and heading, confirm the fuel and output sides, then use the explicit `chunk_dig <chunks> [job name]` command. Don't start a new job from the turtle's mid-quarry position.

## One-time migration

Your currently running pre-persistence quarry has no checkpoint, and this version cannot infer its original home or exact next action. Let it finish on the old script if you can. Otherwise stop it, recover the turtle and cargo manually, and put the turtle back at the original base cell and facing before upgrading. Check the storage-side settings in the new version.

If a legacy `/chunk_dig` already exists, after stopping the old job you can save it as `move /chunk_dig /chunk_dig_legacy` before using the download command. Then either start an explicitly new job from the original base (it will rescan the footprint, including existing air), or use a different known base. Enable auto-resume for the new version only. Don't use `resume` or `resolve` as a migration step.

## Testing

`test_quarry.py` runs `chunk_dig.lua` against mock turtle, peripheral, rednet, and GPS APIs (Python and `lupa`):

```text
pip install lupa
python3 cctweaked/turtle/test_quarry.py
```

The harness checks the existing quarry behavior and abandons the running Lua coroutine at chosen points before and after moves, turns, digs, transfers, checkpoint publication and phase changes. It boots the startup script against the retained mock world and filesystem, checks for exact continuation without dropped cargo or skipped cells, and exercises waiting states, manual reconciliation, invalid state, and completed jobs. These are mocked process restarts, **not** actual Minecraft chunk unload/reload tests. For an in-game smoke test, use a small sacrificial job, travel far enough to unload it naturally, then return and check `chunk_dig status` or the dashboard before trying it on a large quarry.
