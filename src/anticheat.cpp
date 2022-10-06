#include "anticheat.h"
#include <string>
#include "enginecallback.h"
#include "eiface.h"
#include "utils.h"
#include <algorithm>

using namespace std;

#define MAX_CLOCK_ERROR_SECONDS 0.3f // how different client/server clocks can be before cheating is suspected
#define MAX_SUSSY_SECONDS 1.0f // how long cheating must be suspected before punishing player

// Description of plugin
plugin_info_t Plugin_info = {
	META_INTERFACE_VERSION,	// ifvers
	"AntiCheat",	// name
	"1.0",	// version
	__DATE__,	// date
	"w00tguy",	// author
	"https://github.com/wootguy/",	// url
	"ANTICHEAT",	// logtag, all caps please
	PT_ANYTIME,	// (when) loadable
	PT_ANYPAUSE,	// (when) unloadable
};

void PluginInit() {
	g_dll_hooks.pfnStartFrame = StartFrame;
	g_newdll_hooks.pfnCvarValue2 = CvarValue2;
}

void PluginExit() {}

void CvarValue2(const edict_t* pEnt, int requestID, const char* cvarName, const char* value) {
	if (requestID != 1337 || value[0] == 'B') {
		// "Bad CVAR request" or "Bad Player"
		RETURN_META(MRES_IGNORED);
	}

	println("[AntiCheat_mm] %s: %s = %s", STRING(pEnt->v.netname), cvarName, value);
	logln("[AntiCheat_mm] %s: %s = %s", STRING(pEnt->v.netname), cvarName, value);

	if (strcmp(cvarName, "sc_speedhack") == 0 || strcmp(cvarName, "sc_speedhack_ltfx") == 0) {
		g_engfuncs.pfnServerCommand(UTIL_VarArgs("as_command anticheat.cheaterFound %d;", ENTINDEX(pEnt)));
	}

	RETURN_META(MRES_IGNORED);
}

uint64_t lastCheck = 0;

void StartFrame() {
	uint64_t now = getEpochMillis();
	if (TimeDifference(lastCheck, now) < 10.0f) {
		return;
	}

	lastCheck = now;

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		(*g_engfuncs.pfnQueryClientCvarValue2)(plr, "sc_speedhack", 1337);
		(*g_engfuncs.pfnQueryClientCvarValue2)(plr, "sc_speedhack_ltfx", 1337);
	}
	RETURN_META(MRES_IGNORED);
}
