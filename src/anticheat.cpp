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

struct PlayerDat {
	uint64_t lastCmd;
	uint64_t msecTime; // time accumulated by the msec value in each Cmd
	uint64_t cheatTime; // time that msecTime was too different from server time
	uint64_t gracePeriodEnd; // time after lag spike that cheat checks should resume
};

PlayerDat playerDat[32];

uint64_t lastDriftCorrection = 0;

void PluginInit() {
	memset(playerDat, 0, sizeof(PlayerDat) * 32);
	println("HELLO PLUGIN INIT");

	g_dll_hooks.pfnCmdStart = CmdStart;
	g_dll_hooks.pfnServerActivate = MapInit;
	g_dll_hooks.pfnStartFrame = StartFrame;
	g_dll_hooks.pfnClientPutInServer = ClientJoin;
	g_dll_hooks.pfnClientDisconnect = ClientLeave;

	g_newdll_hooks.pfnCvarValue2 = CvarValue2;
}

void PluginExit() {}

void CvarValue2(const edict_t* pEnt, int requestID, const char* cvarName, const char* value) {
	if (requestID != 1337 || value[0] == 'B') {
		// "Bad CVAR request" or "Bad Player"
		RETURN_META(MRES_IGNORED);
	}

	if (strcmp(cvarName, "sc_speedhack") == 0 || strcmp(cvarName, "sc_speedhack_ltfx") == 0) {
		g_engfuncs.pfnServerCommand(UTIL_VarArgs("as_command anticheat.cheaterFound %d;", ENTINDEX(pEnt)));
	}
	//string cheatName = cvarName;
	//println("%s: %s = %s", STRING(pEnt->v.netname), cvarName, value);

	RETURN_META(MRES_IGNORED);
}

void MapInit(edict_t* pEdictList, int edictCount, int clientMax) {
	memset(playerDat, 0, sizeof(PlayerDat) * 32);
}

void ClientJoin(edict_t* plr) {
	int idx = ENTINDEX(plr) - 1;
	memset(&playerDat[idx], 0, sizeof(PlayerDat));

	RETURN_META(MRES_IGNORED);
}

void ClientLeave(edict_t* plr) {
	int idx = ENTINDEX(plr) - 1;
	memset(&playerDat[idx], 0, sizeof(PlayerDat));

	RETURN_META(MRES_IGNORED);
}

void StartFrame() {
	uint64_t now = getEpochMillis();
	if (TimeDifference(lastDriftCorrection, now) < 2.2f) {
		return;
	}

	lastDriftCorrection = now;

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		PlayerDat& dat = playerDat[i-1];

		if (dat.msecTime == 0) {
			continue;
		}

		float diff = TimeDifference(dat.msecTime, getEpochMillis());

		// slowly correct the clock difference to fix false positives for really bad connections
		if (diff >= 0.1) {
			dat.msecTime += 10;
		}
		else if (diff < -0.1) {
			dat.msecTime -= 10;
		}

		float timeSinceLastPacket = TimeDifference(dat.lastCmd, now);

		(*g_engfuncs.pfnQueryClientCvarValue2)(plr, "sc_speedhack", 1337);
		(*g_engfuncs.pfnQueryClientCvarValue2)(plr, "sc_speedhack_ltfx", 1337);

		//println("[AntiCheat] %s: t=%llu, error=%.2f, lastCmd=%.2f", STRING(plr->v.netname), dat.msecTime, (float)diff, timeSinceLastPacket);
	}
	RETURN_META(MRES_IGNORED);
}

void CmdStart(const edict_t* plr, const struct usercmd_s* cmd, unsigned int random_seed) {
	int idx = ENTINDEX(plr) - 1;

	if (idx == 0) {
		return; // test
	}

	PlayerDat& dat = playerDat[idx];

	uint64_t now = getEpochMillis();

	if (dat.msecTime == 0) {
		dat.msecTime = now + cmd->msec;
		dat.lastCmd = now + cmd->msec;
	}
	else {
		dat.msecTime += cmd->msec;
	}

	float timeSinceLastPacket = TimeDifference(dat.lastCmd, now);
	if (timeSinceLastPacket > 0.3f) {
		// forgive clock errors after a lag spike
		uint64_t forgive = (timeSinceLastPacket * 0.9f) * 1000;
		//dat.msecTime += forgive;

		uint64_t grace = timeSinceLastPacket * 1000;
		dat.gracePeriodEnd = now + min(500, grace); // give a little time to align clocks
		println("FORGIVE LAG SPIKE");
	}
	dat.lastCmd = now;

	float diff = TimeDifference(dat.msecTime, getEpochMillis());
	bool isGracePeriod = dat.gracePeriodEnd > now;

	if (isGracePeriod) {
		dat.msecTime = now + cmd->msec;
	}
	else if (fabs(diff) > MAX_CLOCK_ERROR_SECONDS) {
		if (dat.cheatTime == 0) {
			dat.cheatTime = now;
			println("[AntiCheat] %s: sussy time diff", STRING(plr->v.netname));
		}
		else {
			if (TimeDifference(dat.cheatTime, now) > MAX_SUSSY_SECONDS) {
				println("\n\nKILL % s FOR SPEEDHACK\n\n", STRING(plr->v.netname));
				ClientPrintAll(HUD_PRINTTALK, UTIL_VarArgs("KILL %s FOR SPEEDHACK\n", STRING(plr->v.netname)));
				dat.msecTime = 0;
				dat.cheatTime = 0;
			}
		}
	}
	else {
		if (dat.cheatTime > 0) {
			//println("[AntiCheat] %s: not sussy anymore", STRING(player->v.netname));
		}
		dat.cheatTime = 0;
	}

	
	//println("[AntiCheat] %s: t=%llu, error=%.2f, lastCmd=%.2f, msec=%d, grace=%d", STRING(plr->v.netname), dat.msecTime, (float)diff, timeSinceLastPacket, cmd->msec, isGracePeriod);

	RETURN_META(MRES_IGNORED);
}
