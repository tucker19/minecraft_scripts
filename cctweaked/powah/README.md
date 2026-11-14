# Powah reactor monitoring

| Script | Runs on | Purpose |
|---|---|---|
| `wired_reactor.lua` | Computer on a wired-modem network of reactors | Local-monitor-only version: finds every `uraninite_reactor` on the network and draws each reactor plus a combined-energy donut gauge, dynamically sized to the monitor (minimum 3x3). No wireless broadcast. |
| `wired_reactor_bank.lua` | Same computer, plus a wireless/ender modem on a free side | Bank version of the above: takes the bank name as an argument, shows reactors on the local monitor, and broadcasts each one to the dashboard as `<Bank Name> R1`, `R2`, ... Also finds `thermo_generator` peripherals. |
| `reactor_wireless_sender.lua` | Computer touching a single reactor | Sends one reactor's readings to the dashboard. Accepts a dashboard hostname or numeric ID. |
| `reactor_wireless_dash.lua` | Dashboard computer with monitor + modem | Registers a rednet hostname, auto-discovers reactors, scales text/columns to the monitor, and forwards snapshots to pockets on `powah_pocket_v1`. |
| `reactor_wireless_pocket.lua` | Advanced Ender/Wireless Pocket Computer | Paged pocket view of reactor status (green active, yellow idle-charged, red inactive, gray offline). |

Protocols: `powah_telemetry_v1` (senders → dash), `powah_pocket_v1` (dash → pocket).

## startup.lua examples

```lua
-- wired bank
shell.execute("/wired_reactor_bank", "Nitro Reactor Bank 00")
-- single reactor sender
shell.execute("/reactor_wireless_sender", "Spirited Reactor 0", "reactor_wireless_dash")
-- dashboard
shell.execute("/reactor_wireless_dash", "reactor_wireless_dash")
-- pocket
shell.execute("/reactor_wireless_pocket", "reactor_wireless_dash")
```
