# Draconic Evolution Energy Core monitoring

| Script | Runs on | Purpose |
|---|---|---|
| `draconic_wireless_sender.lua` | Computer touching the Energy Pylon (`draconic_rf_storage`) | Reads stored energy, capacity, and input/output rates and sends them to the dashboard. |
| `draconic_wireless_dash.lua` | Main dashboard computer with monitor + modem | Tracks every reporting core, draws a large combined storage circle, and broadcasts all cores to pockets and remote dashboards. Hostname defaults to the computer label. |
| `draconic_wireless_remote.lua` | Second dashboard computer elsewhere | Mirrors the main dashboard (circle included) from its broadcasts; does not register a hostname or rebroadcast. |
| `draconic_wireless_pocket.lua` | Advanced Ender Pocket Computer | Cycles through all discovered cores. |

Colors: green = charging (input > output), red = draining, yellow = balanced, orange = offline/disconnected.

## startup.lua examples

```lua
-- sender: core name, dashboard hostname, pylon side
shell.execute("draconic_wireless_sender", "Energy Core 0", "draconic_wireless_dash", "back")
-- main dashboard (label the computer draconic_wireless_dash)
shell.execute("draconic_wireless_dash")
-- remote dashboard
shell.execute("draconic_wireless_remote", "draconic_wireless_dash")
-- pocket
shell.execute("draconic_wireless_pocket", "draconic_wireless_dash")
```
