# AntiCheat
VAC is not updated for Sven Co-op and so plugins are needed to block cheaters. This plugin blocks the following cheats:
- Speedhack (moving/shooting too fast or slow)
- Jumpbug (preventing fall damage)

# CVars
`anticheat.enable 1` Enables/disables the plugin.  

`anticheat.maxCmdProcessMs 300`  
Total milliseconds of command packets that clients can send instantly after a lag spike. This is also the max time a speedhacker can speed up or slow down movements before needing to "recharge" by throttling packets.
- Too high = speedhacks are too powerful.
- Too low = players with bad connections can't play without constant rubber-banding.

During my testing 150ms seemed to be a good value without causing problems for too many players. Like maybe 90% of normal players would not ever be throttled by accident. Then 300ms prevents maybe 95% of false positives. There's diminshing returns after that. Trusted players with bad connections should be added to the whitelist file (see below).

`anticheat.minthrottlemslog 50` Don't log speedhack throttles unless the speedup/slowdown is greater than this (milliseconds).

`anticheat.logcmd 0`  
Controls client command logging. It can be used to find out if a command is being spammed to cause lag or something.
- 0 = Disable
- 1 = Log all commands that aren't filtered by `anticheat_command_filter.txt` or the built-in filter.
- 2 = Log all commands with no filter. 

`anticheat.cheatclientcheck 1` Auto-kicks players that have special cvars defined by the sven_internal cheat mod. Only catches cheaters that use the public version of sven_internal without the bypass plugin (rare, maybe once per month).

# Commands
`.ac <player name>` Analyze a player's connection to the server. You can use this to find players who have bad connections, and decide if they should be added to the whitelist file (see next section). Type `.ac` without a player name to disable debugging.

The circle inside the bar represents the client's "clock" relative to the server's. The plugin prevents the player's clock from being too far out of sync (+/- `anticheat.maxCmdProcessMs` / 2). The circle falls to the left when the player has a lag spike, then shoots back up to where it was, or else gets throttled if the lag spike was beyond the acceptable range.

A lot of throttling comes from people alt-tabbing out of the game. You can usually tell this happens when they stop moving and their FPS dips to ~30 or so.

# Speedhack whitelist
The `anticheat_speedhack_whitelist.txt` file lists players who have utterly shit connections and are constantly throttled by this plugin. Half-Life is very forgiving of connection issues and will let players queue many seconds of input commands while disconnected. The problem is that AntiCheat will stop compensating after 300ms or so (`antcheat.maxcmdprocessms` cvar), which means laggers get teleported back in time when they reconnect. A few small throttles per map is hardly noticeable but more than once per minute is going to ruin the game for some people.

Only add people to this file if you trust that they are not actually speedhacking. It should be obvious if they are regulars, or after analyzing their connection quality with the `.ac <player name>` command.

# Installation
1. Extract AntiCheat.dll (Windows) or AntiCheat.so (Linux) to `svencoop/addons/metamod/dlls/`.
1. Add the plugin path to metamod's plugins.ini file.
    * Windows: `win32 addons/metamod/dlls/AntiCheat.dll`
    * Linux: `linux addons/metamod/dlls/AntiCheat.so`
1. Extract `anticheat_command_filter.txt` and `anticheat_speedhack_whitelist.txt` to the Sven Co-op root folder (one level up from `svencoop`).
