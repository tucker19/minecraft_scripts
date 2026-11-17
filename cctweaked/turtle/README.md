# Turtle scripts

| Script | Purpose |
|---|---|
| `chunk_dig.lua` | Digs a chunk-sized square straight down to bedrock and climbs back home. |

## `chunk_dig.lua`

```text
chunk_dig 3
```

The argument is the size in chunks: `1` digs a 16x16 hole, `2` a 32x32 (2x2 chunks), `3` a 48x48 (3x3 chunks). Each pass clears 3 layers with a serpentine sweep, the turtle returns to its starting corner, drops down 3 more layers, and repeats until it hits bedrock. It then climbs back to the exact starting corner.

## Notes

- **Chunk alignment**: the square starts at the turtle. Place the turtle at a chunk corner (F3 + G to see chunk borders) if you want the hole aligned with chunk boundaries.
- **Inventory**: put an ender chest in slot 16. When 15+ slots fill, the turtle places it above itself, drops everything in, and reclaims the chest. Without one it warns when nearly full.
- **Fuel**: each pass costs about `SIDE^2 + 4*SIDE` fuel. A 1-chunk dig to bedrock is roughly 15k fuel (~19 coal blocks); bigger areas scale fast. The turtle refuses to start a pass it can't finish and keeps a reserve for the climb home.
- **Lava**: the turtle does not detect lava. If you break into a lava pocket it can be destroyed - bring a backup, or dig where you've already explored.
- **Chunk loading**: the turtle only runs while its chunks are loaded (you nearby, or a chunk loader).
- **Mid-run refuel**: if it stops for fuel, refuel and rerun the same command; it re-digs its way down through the already-cleared layers and continues.

## startup.lua example

```lua
shell.execute("/chunk_dig", "3")
```
