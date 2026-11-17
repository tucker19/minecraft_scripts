# minecraft_scripts

Scripts I use on my Minecraft servers (currently All the Mods 10).

## Layout

| Directory | Contents |
|---|---|
| [`cctweaked/`](cctweaked/) | Lua programs for CC: Tweaked computers |
| [`cctweaked/powah/`](cctweaked/powah/) | Powah reactor monitoring: wired bank monitor, wireless sender, dashboard, pocket viewer |
| [`cctweaked/draconic_evolution/`](cctweaked/draconic_evolution/) | Draconic Evolution Energy Core monitoring: sender, dashboard, remote dashboard, pocket viewer |
| [`cctweaked/turtle/`](cctweaked/turtle/) | Chunk quarry with a home base (output barrel + fuel inventory), fuel budgeting and resume, plus a multi-turtle wireless dashboard |

## Installing on an in-game computer

Download a file straight from GitHub with `wget` (HTTP must be enabled in the CC: Tweaked server config):

```sh
wget https://raw.githubusercontent.com/tucker19/minecraft_scripts/main/cctweaked/powah/reactor_wireless_dash.lua reactor_wireless_dash
```

Save programs without the `.lua` extension if you want to match the startup commands below.
