# Turtle quarry and wireless dashboard

`chunk_dig.lua` mines a square measured in chunks. `turtle_wireless_dash.lua` receives all reporting turtles automatically on `turtle_quarry_v1`. There is no dashboard ID to configure. Give each turtle a label or pass a job name.

## Download and run

On a mining turtle:

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/chunk_dig.lua chunk_dig
chunk_dig 1 "Mining Quarry 01"
```

The first argument is the square's side length in chunks: `1` = 16×16, `2` = 32×32, `3` = 48×48 blocks. The optional second argument is the displayed job name. The footprint starts at the turtle's cell and extends **forward and right**. Align it to chunk boundaries yourself if needed.

On the dashboard computer with a wireless/Ender modem and, optionally, a monitor:

```text
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/turtle/turtle_wireless_dash.lua turtle_wireless_dash
turtle_wireless_dash "turtle_wireless_dash"
```

The optional argument sets the dashboard hostname; otherwise it uses its computer label or `turtle_wireless_dash`. Left/right arrows, mouse wheel, or monitor touches change pages. Only changed display rows are redrawn.

Dashboard-only `/startup.lua`:

```lua
shell.execute("/turtle_wireless_dash", "turtle_wireless_dash")
```

Do not automatically restart the quarry after reboot: this version does not persist its position/job state.

## Wireless detection and telemetry

Equip the mining turtle with a mining tool and a wireless or Ender modem upgrade. A modem carried as cargo is not equipped. With no modem the quarry still runs locally. With a modem it automatically broadcasts about every 2 seconds during work and while waiting; stopped/completed jobs keep reporting until Ctrl+T.

The dashboard lists every turtle separately by computer ID:

- **Fuel type:** the item ID most recently consumed, not an assumed fuel type. Before fuel is consumed this reads `none consumed yet`.
- **Fuel amount:** remaining movement fuel and tank limit, including `unlimited` mode.
- **Job size:** N×N chunks, block dimensions, current layer and visited cells. Depth to bedrock is unknown at launch, so no fabricated completion percentage is shown.
- **Inventory:** occupied cargo slots out of 14 plus item count. Slots 15 and 16 are excluded because they are reserved for portable storage. The packet also includes occupied-slot percentage.
- **Location:** tracked offsets from the starting cell: forward, up and right. Optional GPS fixes are sampled about every 15 seconds; their age is shown. Without a GPS network, offsets are still available, but they are not world XYZ.
- **Status:** mining, fuel/inventory waiting, bypassing, returning, complete or stopped. No new packet for 15 seconds marks a turtle offline.

## External fuel storage

Use a **fuel-only** chest or barrel. The turtle uses the CC:Tweaked `suckUp` API to pull from storage directly above it, and `refuel` to consume valid fuel ([turtle API](https://tweaked.cc/module/turtle.html)).

Two supported arrangements:

- **Fixed storage above the turtle:** loads fuel before starting. Once the turtle moves away it cannot reach that chest. It does not navigate back to a fixed fuel depot.
- **Portable storage in slot 15:** the turtle places it above itself when needed, pulls fuel and retrieves it. A linked Ender chest is useful for resupplying it remotely, provided that mod's chest supports turtle placement, inventory access and retrieval. Test with a small job first.

Slots 1–14 hold fuel/cargo. When movement fuel drops to 100 or less, the turtle consumes carried fuel, then pulls external fuel toward a 4,000-fuel target (or the tank limit). It waits if it cannot get above the low-fuel threshold. You can insert fuel directly or place fuel storage above it. Telemetry continues while it waits.

Portable fuel storage needs empty space above the turtle. If blocked, it pauses for fuel instead of blindly destroying the overhead block/storage. Non-fuel items and leftover containers are returned to the source when possible; fuel-only storage avoids repeatedly pulling the wrong item. There is a bounded number of pulls per attempt.

## Cargo output

Reserve slot 16 for a portable output chest, separate from the slot-15 fuel chest. When all 14 cargo slots are occupied, the turtle tries placing the output chest above, unloading non-fuel cargo, and retrieving it. If the chest is absent/full or there is no overhead clearance, it pauses for manual intervention instead of knowingly continuing with a full cargo inventory.

Use two distinct linked Ender chest networks for fuel and cargo. For ordinary portable chests/barrels, verify that breaking the storage preserves its contents; ordinary vanilla chests do not provide persistent portable storage. A vanilla chest above the initial turtle works as a stationary fuel source.

## Mining, obstacles and safety

This version uses **one layer per sweep**, not the original three-layer algorithm. This simplifies position tracking and obstacle handling. It returns across the cleared layer, descends at the origin column, and ends when that column first reaches `minecraft:bedrock`; uneven bedrock means deeper pockets elsewhere are not fully cleared. It then climbs to the starting cell.

Allthemodium-namespace ore blocks are skipped before attempting to dig. Horizontal obstacles are bypassed by traveling above them and returning to the working layer at a clear cell, with every movement tracked. Blocked bypasses, blocked descent, or protection errors stop the job and report the reason rather than guessing a route. Some blocks remain for manual mining.

Keep the job area loaded. A stopped job remains in place; a terminal error is not a completed quarry. **There is no persistent resume after restart, Ctrl+T or reboot.** Retrieve the turtle to a known starting position before launching a new run. Do not manually move it while a job is running: relative position would become incorrect. This is not a lava-containment or liquid-removal program.
