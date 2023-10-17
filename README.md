# AntiCheat
VAC is not updated for Sven Co-op and so plugins are needed to block cheaters. This plugin blocks the following cheats:
- Speedhack (moving/shooting too fast or slow)
- Jumpbug (preventing fall damage)
- Fastcrowbar (gib players with the crowbar and some form of undetected speedhack)
- Autostrafe (inhumanly fast bunny hop acceleration in a straight line + fast running)

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

`anticheat.blockgamebans 0` Allows game-banned players to join your server. For when you disagree with the sven devs on who should be allowed to join your server.

`anticheat.autostrafe 1` Blocks the autostrafe cheat. That cheat toggles strafes inhumanely fast which quickly accelerates you when bunny hopping, and in a straight line. It also lets you run faster than normal. A slower form of this is still possible. Strafe toggles >16 per second are ignored.

`anticheat.logmodelinfo 0` Log model names for every player, including whenever the model changes. This can help find player models that cause client crashes.

# Commands
`.ac <player name>` Analyze a player's connection to the server. You can use this to find players who have bad connections, and decide if they should be added to the whitelist file (see next section). Type `.ac` without a player name to disable debugging.

The circle inside the bar represents the client's "clock" relative to the server's. The plugin prevents the player's clock from being too far out of sync (+/- `anticheat.maxCmdProcessMs` / 2). The circle falls to the left when the player has a lag spike, then shoots back up to where it was, or else gets throttled if the lag spike was beyond the acceptable range.

A lot of throttling comes from people alt-tabbing out of the game. You can usually tell this happens when they stop moving and their FPS dips to ~30 or so.

# Speedhack whitelist
The `anticheat_speedhack_whitelist.txt` file lists Steam IDs to disable speedhack checks for. Trusted players with terrible connections should be added to this file.

Half-Life is very forgiving of connection issues and will let players queue many seconds of input commands while disconnected. The problem is that AntiCheat will stop compensating after 300ms or so (`antcheat.maxcmdprocessms` cvar), which means laggers get teleported back in time when they reconnect. A few small throttles per map is hardly noticeable but more than once per minute is going to ruin the game for some people.

Only add people to this file if you trust that they are not actually speedhacking. It should be obvious if they are regulars, or after analyzing their connection quality with the `.ac <player name>` command.

# Installation
1. Extract AntiCheat.dll (Windows) or AntiCheat.so (Linux) to `svencoop/addons/metamod/dlls/`.
1. Add the plugin path to metamod's plugins.ini file.
    * Windows: `win32 addons/metamod/dlls/AntiCheat.dll`
    * Linux: `linux addons/metamod/dlls/AntiCheat.so`
1. Extract `anticheat_command_filter.txt` and `anticheat_speedhack_whitelist.txt` to the Sven Co-op root folder (one level up from `svencoop`).

### [Build instructions](https://github.com/wootguy/mmlib/blob/master/README.md#generic-build-instructions-for-plugins-that-use-mmlib)
