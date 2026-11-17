# CC: Tweaked scripts

Lua programs for [CC: Tweaked](https://tweaked.cc/) Advanced Computers and Pocket Computers, mainly used for wireless energy telemetry over `rednet` with Wireless or Ender Modems.

- [`powah/`](powah/) — Powah reactor (and thermo generator) monitoring.
- [`draconic_evolution/`](draconic_evolution/) — Draconic Evolution Energy Core monitoring.
- [`turtle/`](turtle/) — Chunk quarry with external fuel loading and a wireless fleet dashboard.

General data flow for both:

```text
Sender computer(s) → Dashboard computer (monitor) → Pocket computer / remote dashboards
```

Use `shell.execute(...)` in one-line `startup.lua` files so arguments with spaces are passed correctly.
