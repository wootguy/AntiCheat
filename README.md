# AntiCheat
VAC does not work in Sven Co-op and so plugins are needed to detect cheaters. This plugin kills players who use the "Speedhack" feature in Cheat Engine to move and shoot faster. It's not perfect. Rarely, it will kill players who have an abnormal server connection.

The way it works is by detecting if the player is moving faster than their velocity value, or if their weapon is shooting faster than the cooldown time should allow.

Previously used methods that were removed because they kill normal players:
- Checking if client FPS is above 200.
  - This was very simple and reliable, but it doesn't work because `fps_override 1` allows you to set the fps limit to 1000.
- Checking if player weapon idle timers are decreasing faster than the server time increases.
  - Too sensitive to abnormal client connections.

# CVars
`as_command anticheat.enable 1` enables/disables the plugin  
`as_command anticheat.kill_penalty 30` time in seconds to kill players who are caught cheating. It's probably better to set this to ~6 seconds until all false positives are fixed.

# Installation
1. Copy the script to `scripts/plugins/AntiCheat.as`
1. Add this to default_plugins.txt:
```
	"plugin"
	{
		"name" "AntiCheat"
		"script" "AntiCheat"
		"concommandns" "anticheat"
	}
```
