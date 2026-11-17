# Turtle quarry and wireless dashboard

`chunk_dig.lua` digs a square, measured in chunks, from the layer below the turtle down to bedrock. It works out of a fixed base at its starting position. Cargo goes into a stationary output barrel there, and coal blocks come from a stationary fuel inventory. When cargo needs unloading or fuel runs low, the turtle goes home along a route through blocks it has already cleared. After servicing, it returns to the exact cell and heading it left and carries on.

`turtle_wireless_dash.lua` shows every quarry turtle broadcasting on `turtle_quarry_v1`. You don't configure a turtle ID.

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

On a mining turtle with a pickaxe and, optionally, a wireless or Ender modem upgrade:

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/chunk_dig.lua chunk_dig
chunk_dig 1 "Mining Quarry 01"
```

The first argument is the side length in chunks: `1` = 16×16, `2` = 32×32, `3` = 48×48 blocks. The optional second argument is the job name shown on the dashboard; without it the turtle label is used. Align the turtle to chunk boundaries yourself if you need that.

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

Do not put `chunk_dig` in a turtle's `startup.lua` (see [Restart limitations](#restart-limitations)).

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
| `error` | Base inventories missing at start, the round trip exceeds the fuel limit, or an internal consistency check failed. | Stops in place with slot 1 selected. |
| `stopped` | Terminated with Ctrl+T. | Stops in place. |

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

The protocol is still `turtle_quarry_v1`, version 1. New fields (`fuelLimit`, `reserve`, `heading`, `layerCleared`, `layerBlocked`, `layerSkipped`, `trips`, and `gps.moved`) were added without changing existing ones. Update both scripts together.

## Chunk loading

Turtles stop when their chunk unloads. Keep the whole quarry footprint and the base chunk loaded while the job runs, for example with a chunk loader or FTB Chunks claims with force-loading, or by staying nearby.

## Restart limitations

Job state is not saved. If the turtle reboots, the server restarts, the chunk unloads, or you press Ctrl+T, the job ends where the turtle stands. Starting `chunk_dig` again would treat that spot as a new home and begin a new quarry there, so the program does not run automatically from `startup.lua`. To continue, move the turtle back to the original home cell and facing by hand, then start a new run. Already-cleared layers are simply passed through as empty space.

## Testing

`test_quarry.py` runs `chunk_dig.lua` against mock turtle, peripheral, rednet, and GPS APIs (Python and `lupa`):

```text
pip install lupa
python3 cctweaked/turtle/test_quarry.py
```

The scenarios cover all 16 slots in use, slot 1 restored after inventory work, fuel through slot 1 at base, returning when no slot is empty, exact resume, output full then freed, fuel supply empty then restocked, low-fuel return, unlimited fuel, a fuel limit that is too small, failed moves without position drift, Allthemodium detours that change elevation, bedrock pockets that split a layer, configurable storage sides, missing inventories, stale GPS, a 2-chunk job, and the dashboard rendering. This is simulation only; it does not replace a careful first run in game.
