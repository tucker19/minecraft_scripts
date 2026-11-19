# Turtle quarry and wireless dashboard

`chunk_dig.lua` digs a square, measured in chunks, from the layer below the turtle down to bedrock. By default one stationary inventory behind the starting position receives mined cargo and supplies coal blocks. When cargo needs unloading or fuel runs low, the turtle goes home along a route through blocks it has already cleared. After servicing, it returns to the exact cell and heading it left and carries on.

`turtle_wireless_dash.lua` shows every quarry turtle broadcasting on `turtle_quarry_v1`. You don't configure a turtle ID.

For multiple turtles working from one dynamic patch queue, see [Opt-in swarm setup](#opt-in-swarm-setup). Swarm is a separate program and does not replace a saved standalone job.

The turtle saves an active job to its own filesystem. It stops when its chunk unloads and can continue the same job when the chunk loads and the computer boots. A chunk loader is not required. An interrupted action whose outcome cannot be established safely pauses for verification instead of risking a wrong move.

## Base placement and configuration

Home is the turtle's original cell and facing when you start the program. The quarry extends forward and to the right of home. Digging starts one block below home, so the home level (and anything beside the turtle) is never dug.

Two settings at the top of `chunk_dig.lua` say where the base inventories are, relative to the turtle's starting facing:

```lua
local OUTPUT_SIDE = "back"
local FUEL_SIDE   = "back"
```

### Shared storage and wired fuel dock

1. Put the storage immediately behind the turtle at home and stock it with `minecraft:coal_block`. For unloading, CC:Tweaked must detect its generic `inventory` type on the turtle-facing side, and that side must accept the cargo. The script deposits directly; no wired modem, remote name, `pullItems`, or `getItemDetail` is required for output.
2. For automatic fuel only, put a **Wired Modem (Full Block)** directly above home and another directly above the shared storage. They share a face and connect directly. Use a dedicated network: the only inventory on it other than the turtle must be the one physically behind home. Do not place unrelated inventories beside either modem.
3. Put a stationary non-inventory CC peripheral (for example, a CC computer) directly above the home modem as a keepalive. It needs no program. Activate peripheral mode on both full-block modems by right-clicking them with the turtle home. The home modem can switch off if all its local peripherals disappear, so leave the keepalive in place while the turtle is away ([CC:Tweaked full-block modem implementation](https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/mc-1.21.x/projects/common/src/main/java/dan200/computercraft/shared/peripheral/modem/wired/WiredModemFullBlockEntity.java)).

With the turtle at home in its original facing, this optional Lua REPL diagnostic checks the direct `inventory` type and shows what each wired endpoint exposes ([peripheral API](https://tweaked.cc/mc-1.21.x/module/peripheral.html), [modem API](https://tweaked.cc/peripheral/modem.html)):

```lua
print(peripheral.hasType("back","inventory")); local m=peripheral.wrap("top"); if m and m.getNameLocal then print(m.getNameLocal()); for _,n in pairs(m.getNamesRemote()) do print(n,textutils.serialize(m.getMethodsRemote(n))) end end
```

For a saved job, prefer `chunk_dig status` at home. It maps the configured side using the saved heading and reports the peripheral types and generic `inventory` capability without turning. At heading `3`, home `back` is current `left`; an empty reading from current front or back does not say anything about that storage. The [turtle API](https://tweaked.cc/module/turtle.html) can inspect blocks straight ahead or vertically, not to the left or right, so `status` reports when the block itself was not inspected. If a turn is pending, the command shows the journal instead of probing the base sides.

On `resume`, shared base service turns in place to face horizontal storage before checking the front peripheral or dropping cargo. For `back/back` that means heading `2`; if it still reports `waiting_output`, the message includes the checked physical side, block ID or inspection result, and reported peripheral capabilities. Seeing the expected block with `inventory=false` means the orientation check worked, but the adjacent inventory capability is not exposed on that face. For shared top storage, the turtle faces original forward so it can access the horizontal wired dock from the front.

For fuel, the wired storage must expose `list` and slot-specific `pushItems`, and `pushItems(turtleName, sourceSlot, 1, turtleSlot)` must reach a writable turtle slot. The script obtains the target from `getNameLocal()` and verifies what actually arrived; the network name alone does not prove transfers work. This uses the [CC:Tweaked inventory API](https://tweaked.cc/mc-1.21.x/generic_peripheral/inventory.html) and follows the [maintainer's wired turtle example](https://github.com/cc-tweaked/CC-Tweaked/discussions/601). `getItemDetail` is an optional extra check.

With compacting or sorting storage, a GUI count or listed stack is not proof that a coal block can be extracted. The script refreshes the slot list, tries only reported `minecraft:coal_block` slots, and waits if none delivers a block. If necessary, put actual coal blocks in slots exposed to automation, adjust the storage's extraction or upgrade settings, or supply coal blocks directly to the stopped turtle and resume.

The [inventory API](https://tweaked.cc/mc-1.21.x/generic_peripheral/inventory.html) cannot atomically check the item type and transfer it. Do not remove or replace the storage, rearrange its slots, or let other automation modify either inventory while the turtle is servicing. Disable any voiding behavior on the cargo destination. If a concurrent change delivers a different item, the script stops with `recovery_required` and names the slot. Stop other access, check and remove that unexpected item, then run `chunk_dig resume` without moving or turning the turtle.

### Other placements and separate inventories

Allowed sides are `front`, `back`, `left`, `right` and `top`; `bottom` is reserved for the quarry shaft. For shared storage on another horizontal side, keep the full-block dock modem directly above home and connect the adjacent inventory to it. If both sides are `top`, the dock modem goes in front of home instead. Different sides still use the legacy separate-inventory mode; its fuel inventory should contain only coal blocks. Changing the constants affects new jobs only.

The quarry does not dig at the home level except to clear a gravity block that falls into the home cell itself. Storage blocks are never dug or replaced.

Other settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `SAFETY_MARGIN` | 32 | Fuel kept beyond the exact cost of the route home |
| `MIN_PROGRESS` | 64 | Minimum mining moves a fuel trip must allow before it leaves home |
| `RETRY_SECONDS` | 5 | Delay between retries while waiting for output space, fuel, or a blocked route |

## Download and run

On a mining turtle with a pickaxe and, optionally, a wireless or Ender modem upgrade, download to the root of its filesystem. If `chunk_dig` is already installed, stop it first and follow the matching steps under [Upgrading an existing quarry](#upgrading-an-existing-quarry).

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/chunk_dig.lua /chunk_dig
chunk_dig 1 "Mining Quarry 01"
```

Use the default sides for shared storage behind home. Start only while the turtle is at its base, facing the intended quarry. The first argument is the side length in chunks: `1` = 16×16, `2` = 32×32, `3` = 48×48 blocks. The optional second argument sets the job name; without it the turtle label is used. The plain numeric command refuses to replace existing state, even if the job is complete. See [Archive or start a different job](#archive-or-start-a-different-job) for the explicit replacement command. Align the turtle to chunk boundaries yourself if needed, and note the home block's world coordinates and compass facing so you can verify a pending turn later even without GPS.

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
- Shared-inventory refuelling prefers slot 1, but can use another empty slot (including one freed by compacting cargo or burning a carried coal-block stack). The slot is temporary, not reserved. The turtle checks and burns a transferred coal block explicitly with `turtle.refuel(1)` before unloading again. It never calls `turtle.suck` on shared storage.
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
2. It travels home along recorded cleared cells: inside the current layer to where it entered, then back up through each layer's recorded route. These routes include any up or down steps from detours, so the turtle never assumes a straight path is open. If gravel or sand has fallen into a cleared quarry cell, it is dug again. Another turtle gets a dedicated `waiting_turtle` pause; other route obstructions report `blocked`.
3. At home it burns carried coal blocks first as needed for the next departure, then other carried fuel if needed. It unloads all 16 slots, including surplus fuel, into the barrel. If the barrel cannot accept cargo, the turtle tries to draw and burn available coal blocks from the smallest coal stack to make room, then retries unloading. It finishes refuelling after unloading. On the final trip, it burns shared fuel only if needed to make unloading space and it can do so without overflowing.
4. It returns along the same route in reverse and turns back to the saved heading. It checks that its position matches the saved one, then continues the same sweep. No cell is skipped or repeated, and it doesn't descend an extra layer.

## Waiting and error states

The turtle keeps broadcasting telemetry while waiting.

| Status | Meaning | What happens |
| --- | --- | --- |
| `waiting_output` | Adjacent storage is unverified, full, or rejecting cargo. The detail also says why fuel could not free space. | Stays home with remaining cargo. Make room or fix insertion access; the turtle retries every `RETRY_SECONDS`. |
| `waiting_fuel` | Not enough fuel for departure, and the wired fuel path could not deliver an extractable coal block. | Stays home. Fix the named missing capability, expose actual `minecraft:coal_block`, or supply coal blocks directly to the stopped turtle. |
| `blocked` | A cleared route cell is occupied by something it may not dig, or a mob or entity won't move. | Retries every `RETRY_SECONDS`. |
| `waiting_turtle` | Another turtle occupies the pending action's front, up, or down target. The dashboard shows the blocked direction and target. | Waits 60 seconds without moving, turning, digging, attacking, or advancing the checkpoint. It rechecks the same target and repeats if occupied. After reboot it rechecks before retrying the saved action. |
| `error` | Separate-mode base inventories missing at start, round trip too large for the fuel limit, or another execution error. | Does not continue mining. Fix the reported issue before resuming. |
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
- The quarry recognizes `computercraft:turtle_normal`, `computercraft:turtle_advanced`, and blocks with the `computercraft:turtle` tag ([CC:Tweaked Minecraft 1.21 block-tag data](https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/mc-1.21.x/projects/common/src/generated/resources/data/computercraft/tags/block/turtle.json)). It inspects immediately before every dig, but inspection and digging are separate [turtle API calls](https://tweaked.cc/mc-1.21.x/module/turtle.html), not an atomic compare-and-break. Avoid routing multiple working turtles through the same cell.
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
- **Inventory:** On reboot the live inventory and the persisted temporary fuel-buffer slot determine what is left to unload or refuel. A coal block delivered just before shutdown is burned on reboot before another delivery or unload; a partial unload continues from the slots that still contain cargo. Slot 1 is selected first on startup and restored after temporary selections.
- **Limits:** The turtle filesystem and Minecraft world are not one transaction (see the [CC:Tweaked persistence discussion](https://github.com/cc-tweaked/CC-Tweaked/issues/535)). Don't manually relocate or turn the turtle, change its fuel buffer while a motion is unresolved, or restore its files separately from the world. An arbitrary server crash, world rollback, copied files, or changed terrain can invalidate a checkpoint. Leave room on the turtle filesystem for two checkpoints plus a staged write; larger footprints and long detours use more space.

## Archive or start a different job

Before running `archive` or `new`, stop the quarry with Ctrl+T and wait for movement to settle. To archive without restarting, run:

```text
chunk_dig archive
chunk_dig status
```

`archive` moves the entire `/.chunk_dig` directory, including both checkpoints, the motion journal, and any other contents. It works with incomplete, corrupt, and completed jobs without opening the checkpoints. The first destination is `/.chunk_dig-archive-01`; later archives use one more than the highest existing numbered suffix, so `-01` and `-03` yield `-04`. It does not change the installed program or startup, and `auto` does not resume archived jobs. `status` should report no saved job after a successful archive.

To archive and immediately start a **32×32** quarry, put the stopped turtle at the intended home and face it toward the new quarry before running this command. Confirm the output and fuel setup relative to that facing; do not run it from a mid-quarry position unless you deliberately intend that cell to become home.

```text
chunk_dig new 2 "Mining Quarry 02"
```

`new` accepts the same size, optional name, and optional GPS-facing argument as a numeric start. It checks the arguments, required GPS fix if requested, and initial fuel capacity before archiving. It then starts from the current position and facing using the installed script's configuration, not the archived settings. If there is no saved job, it starts without making an archive. If archiving fails, it does not start; if startup fails after the archive succeeds, the printed archive path remains available and the old job is not restored or resumed automatically.

Keep the archive intact; do not restore individual checkpoint files. An archive preserves files, not the turtle's position, facing, fuel, or world state. Starting another job can invalidate the old job's recovery assumptions.

## Upgrading an existing quarry

### Persistent job using output behind home and fuel above

Installing the new script does not change an active job's saved `output=back, fuel=top`. Leave the old inventories in place until the turtle returns itself to original home. Do not pick it up or drive it home manually. To hold it at base, you can let it reach `waiting_output` with the output barrel full or `waiting_fuel` with the legacy fuel inventory depleted, then stop it with Ctrl+T. If it is waiting on the legacy setup, stop it before replacing the top fuel inventory with the dock.

Back up the old program, download the replacement, and inspect its saved pose. Do not edit or remove `/.chunk_dig`. Preserve existing startup logic.

```text
move /chunk_dig /chunk_dig_legacy
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/chunk_dig.lua /chunk_dig
chunk_dig status
```

With the stopped turtle at original home, no pending motion, and the new wired dock set up, run:

```text
chunk_dig migrate-shared
chunk_dig status
chunk_dig resume
```

The migration checks the adjacent output capability and writes a new checkpoint without moving the turtle, changing its heading, or starting over. It accepts only an active saved `back/top` job at home and requires GPS verification if the job has a GPS anchor. If interrupted, check `status`: `fuel=top` means the change was not committed; `fuel=back` means it was and you can resume. If a pending action prevents migration, use the manual recovery procedure and let the job stop safely at base again. An already shared `back/back` job only needs the updated script and `chunk_dig resume`; its old peripheral name is no longer used for routing.

### Pre-persistence job (no checkpoint)

A pre-persistence quarry has no checkpoint, and this version cannot infer its original home or exact next action. Let it finish on the old script if you can. Otherwise stop it, recover the turtle and cargo manually, and put the turtle back at the original base cell and facing before upgrading. Check the storage-side settings in the new version.

If a legacy `/chunk_dig` already exists, after stopping the old job you can save it as `move /chunk_dig /chunk_dig_legacy` before using the download command. Then either start an explicitly new job from the original base (it will rescan the footprint, including existing air), or use a different known base. Enable auto-resume for the new version only. Don't use `resume` or `resolve` as a migration step.

## Opt-in swarm setup

Run as many mining turtles as you like in one quarry. There are no config or JSON files: you build the bay, start the coordinator, and tell the first turtle how many chunks to dig. The programs work out the rest. These programs have been exercised against simulated CC APIs, not a live server, so try a disposable one-chunk quarry first. The protocol is for a trusted Rednet network only; Rednet does not authenticate senders ([CC:Tweaked Rednet documentation](https://tweaked.cc/module/rednet.html)).

### What you build

The bay is the same layout as the standalone [shared storage and wired fuel dock](#shared-storage-and-wired-fuel-dock). Pick the cell where the first turtle will sit (the bay), facing the direction the quarry should extend:

1. Put **one shared barrel** directly behind the bay and stock it with coal blocks. All mined cargo goes into it too.
2. Put a **Wired Modem (Full Block)** directly above the bay and another directly above the barrel. Put a stationary CC peripheral (a plain computer works) above the bay modem as a keepalive. Activate peripheral mode on both modems. The barrel must be the only inventory on that wired network, and the only inventory beside the bay.
3. Give the **dashboard computer** and **every turtle** a wireless or Ender modem. A working GPS constellation is required.

Nothing else is placed or pre-dug. The quarry covers the same footprint as `chunk_dig.lua`: forward and to the right of the bay, starting one block below it. The first row under the bay becomes the swarm's service lane, and the next row becomes parking spots. The turtles dig both rows first.

### Load the scripts

On the dashboard computer, run each line:

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/swarm_coordinator.lua /swarm_coordinator.lua
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/swarm_patch_queue.lua /swarm_patch_queue.lua
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/swarm_common.lua /swarm_common.lua
```

On every turtle:

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/chunk_dig_swarm.lua /chunk_dig_swarm.lua
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/swarm_common.lua /swarm_common.lua
```

### Kick it off

1. Dashboard computer: `swarm_coordinator`. It waits for the first turtle. To keep the dashboard on the same computer, run `bg swarm_coordinator` and then start `turtle_wireless_dash` as usual.
2. First turtle, in the bay facing the quarry: `chunk_dig_swarm new 1`. The number is the chunk width (1 to 8; the quarry is that many chunks on each side). The coordinator refuses sizes its disk cannot hold, see Size limits below. An optional second number sets the bottom Y (default `-64`), for example `chunk_dig_swarm new 2 10`.
3. Every later turtle: place it in the bay, in any facing and with no fuel, and run `chunk_dig_swarm`. It finds the barrel by turning in place, unloads and refuels from the barrel, drives the lane to the next free parking spot, and starts mining. Add one turtle at a time. If the bay is busy, or no parking spot has been dug yet, it says so and does nothing: lift it out and try again shortly.

What the first turtle does: it checks GPS, the barrel behind it, and the wired dock. If its fuel is under 100, it takes coal blocks from the barrel. It then digs and moves one block down and one block forward, without turning, so GPS reveals its facing. It reports the bay, facing, and chunk count to the coordinator, which builds the quarry ledger. That second cell becomes its parking spot. The turtle never treats a later position as a new home.

### Reboots and chunk unloads

No chunk loaders are needed. When a turtle's chunk unloads, it simply stops. On first setup, each turtle appends `shell.execute("/chunk_dig_swarm","auto")` to the end of its existing `/startup.lua`, after any lines already there (for example `shell.execute("/chunk_dig", "auto")`), and saves the original as `/startup.lua.before_swarm`. If the turtle uses a `/startup/` folder instead, it adds `/startup/99_chunk_dig_swarm.lua`. `auto` resumes saved swarm work or unfinished setup, and does nothing on a turtle with neither. On an advanced computer, the coordinator puts `if multishell then shell.openTab("/swarm_coordinator") end` at the top of `/startup.lua`, with the same backup, so the dashboard program below it still runs. On a basic computer it prints a reminder to add `swarm_coordinator` to startup yourself.

Recovery is GPS-based. An interrupted setup repeats from GPS: the probe only ever moves down and then forward, and a newcomer re-finds the barrel by turning. A pending move resolves by comparing GPS with both saved positions. An interrupted turn during mining cannot be resolved by GPS, so the turtle stops; follow the checklist below. `chunk_dig_swarm status` shows saved state. Missing heartbeats, reboots, and coordinator restarts never release a reservation. A worker that cannot reach the coordinator after a reboot holds still until it can. Independent world or filesystem rollback is not automatically recoverable.

### If you pick up a turtle

- Picked up from the bay before it left (a newcomer still checking the barrel, or any turtle being serviced): put the same turtle back in the bay, facing the way `chunk_dig_swarm status` shows, and run `chunk_dig_swarm`. It continues where it stopped. If any items dropped when you picked it up, put them in the barrel.
- A newcomer you do not want back: place any other turtle in the bay and run `chunk_dig_swarm`. Two turtles cannot be in the bay at once, so the coordinator cancels the old newcomer's join and frees its parking spot. If the old turtle is placed again later, it prints that its join was cancelled, deletes its own `/.chunk_dig_swarm`, and does not move. Run `chunk_dig_swarm` in the bay to join it again.
- While a newcomer still holds the bay, other turtles wait at parking with `join_pending`. A missed heartbeat alone never frees the bay.
- Picked up after it left the bay (in the lane, the parking row, or the quarry): put it back at the position and heading `chunk_dig_swarm status` shows, and run `chunk_dig_swarm`. Its reserved area is not released; there is still no command to release a turtle that has started moving.

### Checklist: status and resolve

Use this when a turtle stopped with a message about a pending turn or move, or you are not sure what it was doing.

1. Stop the program if it is still running (hold Ctrl+T). Do not move the turtle by hand, and do not delete `/.chunk_dig_swarm`.
2. Run `chunk_dig_swarm status`.
   - `Swarm setup in progress` means setup was interrupted. Leave the turtle where it is and run `chunk_dig_swarm`; setup repeats from GPS.
   - `No swarm job on this turtle` means there is nothing to recover.
   - Otherwise it prints `Swarm <quarry> | assignment <id or none> | saved <x,y,z> heading <n> (<direction>)`. Headings are 0 north, 1 east, 2 south, 3 west.
3. Read the `Pending` lines, if any.
   - `Pending forward|up|down: A -> B` is a move. Nothing to do: on resume GPS decides whether the turtle is at A or B. Go to step 6.
   - `Pending turnLeft|turnRight: P -> P, heading a -> b` is a turn that GPS cannot check. Continue with step 4.
   - `Pending <kind> #<n>` is a coordinator request waiting for a reply. Make sure the coordinator computer is running, then go to step 6.
4. Check which way the turtle actually faces. Press F3 and look at the block in front of the turtle (`Targeted Block` coordinates compared with the turtle's coordinates), or note the direction its front face points. North is -Z, east is +X, south is +Z, west is -X.
5. If it still faces heading `a`, run `chunk_dig_swarm resolve before`. If it faces heading `b`, run `chunk_dig_swarm resolve after`. If it faces neither, do not guess. Turn it back to `a` with the Lua prompt (`turtle.turnLeft()` or `turtle.turnRight()`), check again, then run `resolve before`.
6. Run `chunk_dig_swarm` (or `chunk_dig_swarm resume`). It checks GPS against the saved position before moving, and stops again if they disagree.

`resolve` refuses to run when nothing is pending or when the pending step is a move.

### Running notes

- Each turtle keeps its own parking spot as home and uses the bay one at a time, the same way standalone does. At the bay it burns carried coal blocks, unloads cargo, and pulls single coal blocks through the wired dock. It visits the bay when it has cargo, when fuel is below 800, or when a reachable patch needs more fuel.
- Parking is limited to the dug parking row: 16 spots per chunk width, up to 64.

### Size limits

These are limits of this script, not of CC:Tweaked.

- Disk: the coordinator saves the whole quarry map, one character per block for every layer that is partly mined, and keeps two saved copies plus one being written. Before accepting `new`, it checks the worst case (3 x layers x width squared, plus 256 KB) against its free disk space and refuses if it does not fit. On the default 1 MB computer, a quarry from about y=70 down to -64 fits at 1 or 2 chunks, not 3 or more. A server with a larger `computer_space_limit` allows more.
- Speed: each assignment searches outward through the cleared space, so it slows as the quarry grows. In offline tests at 8 chunks it rose from about 45 ms to over 400 ms in plain Lua after 800 assignments; in game it is slower.
- Parking: one row along the quarry edge, 16 spots per chunk width, capped at 64. All turtles share one bay, so beyond a handful of turtles extra ones mostly queue for the bay.
- Chunks: 8 at most, which keeps the map validation and route sizes bounded.
- When nothing reachable remains, turtles wait at parking with `no_safe_patch`. Bedrock and protected Allthemodium ores stay blocked, and cells that cannot be entered are reported as blocked or unverified, never as cleared.
- The dashboard shows the swarm job, assigned area (including `moving to parking`), and waiting reason alongside normal telemetry.
- Do not change the bay layout or start another coordinator during a quarry. To start a new quarry, let all turtles park, stop everything, delete `/.chunk_dig_swarm_coordinator` on the dashboard computer and `/.chunk_dig_swarm` on each turtle, then repeat the kick-off steps. The swarm never opens a standalone `/.chunk_dig` job.

### Advanced: manual manifests

Existing hand-written ledgers still run. `swarm_coordinator init|run|enable-station [config.json]` and `chunk_dig_swarm start` with `/chunk_dig_swarm.json` behave as before. A turtle with `/chunk_dig_swarm.json` refuses automatic setup, so remove that file on turtles joining an automatic quarry. New quarries do not need either file.

## Testing

`test_quarry.py` runs `chunk_dig.lua` against mock turtle, peripheral, rednet, and GPS APIs (Python and `lupa`):

```text
pip install lupa
python3 cctweaked/turtle/test_quarry.py
```

The harness checks the existing quarry behavior and abandons the Lua coroutine around moves, turns, digs, transfers, checkpoint publication and phase changes. Collision tests simulate spare turtles in front, above, and below, including a second wait cycle, a turtle that arrives just before a dig or during a failed move, and reboot during home travel. Shared-inventory tests cover entry and reboot from all four headings, masked peripherals, sorting and virtual coal, and interrupted migration. Archive and new-job tests cover whole-directory preservation, numbering, invalid arguments and preflight failures, failed moves and fresh startup failures, and boot after archiving. These are simulated, not actual modded storage, block placement, or chunk unload/reload tests.

`python3 -m unittest discover -s cctweaked/turtle -p "test_swarm*.py"` runs the swarm suites. The runtime suite runs the real coordinator and worker programs against simulated turtles, GPS, Rednet, wired dock, and filesystem. It covers a zero-config quarry where three turtles define, join, and clear a one-layer chunk, plus a reboot during the first turtle's probe with a lost define reply and a coordinator restart. It also covers a newcomer losing power mid-lane, startup-hook preservation, bay contention, and the earlier collision and station cases. A simulated "cut" stops the program at a chosen move and restarts it from saved files, which models an unload but is not an in-game unload/reload test.

To check your installed build, put a spare turtle in front of a stopped turtle and run `lua`, then `local ok,b=turtle.inspect(); print(ok,textutils.serialize(b))`. Repeat with both turtle types; the result reports the block ID and any inspectable tags. For an in-game collision smoke test, use a disposable quarry and place a spare turtle in the next front/up/down cell before resuming. Leave one through two checks and remove another during a pause. Check that the display stays on `WAITING TURTLE` until the next recheck, then the quarry continues without relocating the mining turtle.

For an in-game smoke test, use a sacrificial one-chunk job. Start with low fuel, non-fuel items before the coal in the shared inventory, and some cargo in the turtle. Check that the cargo is deposited, only coal blocks are withdrawn, and the dock reconnects on a return trip. Empty mined output as needed. Travel far enough to unload the turtle naturally, return, and check `chunk_dig status` or the dashboard.
