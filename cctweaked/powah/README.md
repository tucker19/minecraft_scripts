# Powah reactor monitoring

| Script | Runs on | Purpose |
|---|---|---|
| `wired_reactor.lua` | Computer on a wired-modem network of reactors | Local-monitor-only version: finds every `uraninite_reactor` on the network and draws each reactor plus a combined-energy donut gauge, dynamically sized to the monitor (minimum 3x3). No wireless broadcast. |
| `wired_reactor_bank.lua` | Same computer, plus a wireless/ender modem on a free side | Bank version of the above: takes the bank name as an argument, shows reactors on the local monitor, and broadcasts each one to the dashboard as `<Bank Name> R1`, `R2`, ... Also finds `thermo_generator` peripherals. |
| `reactor_wireless_sender.lua` | Computer touching a single reactor | Sends one reactor's readings to the dashboard. Accepts a dashboard hostname or numeric ID. |
| `reactor_wireless_dash.lua` | Dashboard computer with monitor + modem | Registers a rednet hostname, auto-discovers reactors, scales text/columns to the monitor, and forwards snapshots to pockets on `powah_pocket_v1`. |
| `reactor_wireless_pocket.lua` | Advanced Ender/Wireless Pocket Computer | Paged pocket view of reactor status (green active, yellow idle-charged, red inactive, gray offline). |

Protocols: `powah_telemetry_v1` (senders → dash), `powah_pocket_v1` (dash → pocket).

## Commands

Each script takes its arguments on the command line, so no file edits are needed per machine.

### `wired_reactor.lua`

```text
wired_reactor
```

No arguments. Reads every wired `uraninite_reactor` and draws the local dashboard; no wireless.

### `wired_reactor_bank.lua`

```text
wired_reactor_bank "Nitro Reactor Bank 00"
```

Bank name is optional: without it, the computer's label is used, then `"Bank <id>"`.

### `reactor_wireless_sender.lua`

```text
reactor_wireless_sender "Spirited Reactor 0" "reactor_wireless_dash"
```

Second argument is the dashboard hostname or its numeric ID (`3`). Both arguments are required.

### `reactor_wireless_dash.lua`

```text
reactor_wireless_dash "reactor_wireless_dash"
```

Hostname is optional: without it, the computer's label is used. Passing it explicitly avoids the label-fallback mismatch you hit before.

### `reactor_wireless_pocket.lua`

```text
reactor_wireless_pocket "reactor_wireless_dash"
```

Argument is the dashboard hostname to listen for; defaults to `reactor_wireless_dash`.

## startup.lua examples

```lua
-- old local-only bank
shell.execute("/wired_reactor")
-- wireless bank
shell.execute("/wired_reactor_bank", "Nitro Reactor Bank 00")
-- single reactor sender
shell.execute("/reactor_wireless_sender", "Spirited Reactor 0", "reactor_wireless_dash")
-- dashboard
shell.execute("/reactor_wireless_dash", "reactor_wireless_dash")
-- pocket
shell.execute("/reactor_wireless_pocket", "reactor_wireless_dash")
```
