#include "anticheat.h"
#include <string>
#include "enginecallback.h"
#include "eiface.h"
#include "utils.h"
#include <algorithm>
#include <set>

// TODO: cameras stop PM_Move calls, false slowhack

// abnormal connections:
// greetins = often corrected at 300ms, but less than the disconnect beep
// dj cheb = 50-100ms flucuations normally
// saiko = 250ms+ fluctuations normally
// most false positives come from people alt-tabbing or not having the game in focus


using namespace std;

#define MIN_SPEEDHACK_LOG_DELAY_SECONDS 1.0f // don't log speedhacks for the same player faster than this
#define MIN_SPEEDHACK_DURATION 1.0f // how long to wait until a speed is normalized to consider a hack finished
#define MAX_SPEEDHACK_DURATION 10.0f // don't wait until speed normalizes to log, if hack lasts longer than this
#define JUMPBUG_SPEED 580

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

enum speedhack_states {
	SPEEDHACK_NOT,
	SPEEDHACK_FAST, // speedhacking to go faster
	SPEEDHACK_SLOW, // client clock has been consitently too slow despite constant correction. Must be a speedhack
};

struct PlayerDat {
	int speedhackState = SPEEDHACK_NOT;
	uint64_t lastCmd;

	// speedhack state
	uint64_t msecTime; // time accumulated by the msec value in each Cmd
	uint64_t lastCorrection; // last time player was rubber-banded to prevent speedhack
	uint64_t slowhackStart; // time slow speedhack started, 0 = normal speed resumed

	// log info
	uint64_t lastLogEvent; // last time a speedhack was logged
	uint64_t detectStartTime; // time first speed/slowhack was detected, since last logging
	int fastDetections; // number of speedup millis since last logging - used to indicate hack severity.
	int slowDetections; // number of slowdown detections

	// jumpbug state
	bool jumpOrDuckButtonsChanged;
	bool jumpedInstantlyAfterLanding;
	float lastHealth;
	float lastVelocityZ; // for jumpbug detection

	// debug command info
	int debugTarget; // >0 if debugging player network
	uint32_t lastDebugPacketCount;
	uint32_t packetCount;
	uint64_t lastFpsCalc;
	float lastDebugFps;
};

PlayerDat playerDat[32];

uint64_t lastDriftCorrection = 0;

cvar_t* g_maxErrorSeconds;
cvar_t* g_jumpbugCheck;
cvar_t* g_enabled;
cvar_t* g_log_commands;

set<string> g_cmd_log_filter;

void PluginInit() {
	// Total milliseconds of command packets that clients can send instantly after a lag spike.
	// This is also the max time a speedhacker can speed up or slow down movements before
	// needing to "recharge" by throttling packets.
	// Too high = speedhacks are too powerful
	// Too low = players with bad connections can't play without constant rubber-banding.
	// Test bad connections using the "Throttle" option in clumsy.exe
	// Test speedhacks using sven_internal (sc_speedhack Use < 1.0 to "recharge")
	g_maxErrorSeconds = RegisterCVar("anticheat.maxCmdProcessMs", "300", 300, 0);

	// enables jumpbug checks
	g_jumpbugCheck = RegisterCVar("anticheat.jumpbug", "1", 1, 0);

	g_enabled = RegisterCVar("anticheat.enable", "1", 1, 0);

	// logs all client commands. Used to find out if something is being abused to cause lag or smth
	g_log_commands = RegisterCVar("anticheat.logcmd", "0", 0, 0);

	g_dll_hooks.pfnStartFrame = StartFrame;
	g_newdll_hooks.pfnCvarValue2 = CvarValue2;
	g_dll_hooks.pfnClientPutInServer = ClientJoin;
	g_dll_hooks.pfnServerActivate = MapInit;
	g_dll_hooks.pfnPlayerPreThink = PlayerPreThink;
	g_dll_hooks.pfnPlayerPostThink = PlayerPostThink;
	g_dll_hooks_post.pfnPlayerPostThink = PlayerPostThink_post;
	g_dll_hooks.pfnPM_Move = PM_Move;
	g_dll_hooks_post.pfnPM_Move = PM_Move_post;
	g_dll_hooks.pfnClientCommand = ClientCommand;

	g_cmd_log_filter.insert("say");
	g_cmd_log_filter.insert("gibme");
	g_cmd_log_filter.insert("kill");
	g_cmd_log_filter.insert("drop");
	g_cmd_log_filter.insert("dropammo");
	g_cmd_log_filter.insert("dropsecammo");
	g_cmd_log_filter.insert("medic");
	g_cmd_log_filter.insert("grenade");
	g_cmd_log_filter.insert("npc_findcover");
	g_cmd_log_filter.insert("lastinv");
	g_cmd_log_filter.insert("vmodenable");
	g_cmd_log_filter.insert("vban");
	g_cmd_log_filter.insert("as_menuselect");
}

void PluginExit() {}

void MapInit(edict_t* pEdictList, int edictCount, int clientMax) {
	memset(playerDat, 0, sizeof(PlayerDat) * 32);
	RETURN_META(MRES_IGNORED);
}

void ClientJoin(edict_t* plr) {
	int idx = ENTINDEX(plr) - 1;
	memset(&playerDat[idx], 0, sizeof(PlayerDat));

	RETURN_META(MRES_IGNORED);
}

void check_debuggers() {
	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		PlayerDat& dat = playerDat[i-1];

		if (dat.debugTarget == 0) {
			continue;
		}

		edict_t* target = INDEXENT(dat.debugTarget);
		if (!isValidPlayer(target)) {
			dat.debugTarget = 0;
			continue;
		}
		PlayerDat& tdat = playerDat[dat.debugTarget-1];
		string name = STRING(target->v.netname);
		name = name.substr(0, 14);

		//int error = tdat.lastError;
		uint64_t now = getEpochMillis();
		int error = TimeDifference(now, tdat.msecTime) * 1000.0f;
		int maxErrorMs = g_maxErrorSeconds->value / 2;

		float fpsTime = 1.0f;
		if (TimeDifference(dat.lastFpsCalc, now) > fpsTime) {
			dat.lastDebugFps = ((float)(tdat.packetCount - dat.lastDebugPacketCount) / fpsTime);
			dat.lastDebugPacketCount = tdat.packetCount;
			dat.lastFpsCalc = now;
		}

		bool isLagging = TimeDifference(tdat.lastCmd, now) > 0.1f;

		hudtextparms_t params = { 0 };
		params.effect = 0;
		params.fadeinTime = 0;
		params.fadeoutTime = 0.5f;
		params.holdTime = 1.0f;
		params.r1 = 255;
		params.g1 = isLagging ? 64 : 255;
		params.b1 = isLagging ? 64 : 255;

		params.x = 0.3;
		params.y = 0.4;
		params.channel = 2;

		string bar = "[                    ]";

		int bars = ((float)error / (float)maxErrorMs) * 10.0f;
		bars = clamp(bars, -10, 10);
		bar[11 + bars] = '0';

		if (target->v.flags & FL_FROZEN) {
			bar += UTIL_VarArgs(" FL_FROZEN", tdat.fastDetections);
		}
		else if (tdat.fastDetections > 0) {
			bar += UTIL_VarArgs(" +%dms", tdat.fastDetections);
		}
		else if (tdat.slowDetections > 0) {
			bar += UTIL_VarArgs(" -%dms", tdat.slowDetections);
		}

		HudMessage(plr, params, UTIL_VarArgs("%s\n%s\n%d FPS    (%03d)", name.c_str(), bar.c_str(), (int)dat.lastDebugFps, tdat.packetCount % 1000), MSG_ONE_UNRELIABLE);
	}
}

bool doCommand(edict_t* plr) {
	bool isAdmin = AdminLevel(plr) >= ADMIN_YES;
	PlayerDat& dat = playerDat[ENTINDEX(plr) - 1];
	CommandArgs args = CommandArgs();
	string lowerArg = toLowerCase(args.ArgV(0));

	if (args.ArgC() > 0 && lowerArg == ".ac") {
		dat.debugTarget = 0;

		if (args.ArgC() > 1) {
			edict_t* target = getPlayerByName(plr, args.ArgV(1));

			if (target) {
				dat.lastDebugFps = 0;
				dat.debugTarget = ENTINDEX(target);
				dat.lastDebugPacketCount = playerDat[dat.debugTarget-1].packetCount;
				ClientPrint(plr, HUD_PRINTTALK, UTIL_VarArgs("Debugging network for \"%s\"", STRING(target->v.netname)));
			}
		}

		return true;
	}

	return false;
}

void logClientCommand(edict_t* plr) {
	string command = CMD_ARGV(0);

	for (int i = 1; i < CMD_ARGC(); i++) {
		command += string(" ") + CMD_ARGV(i);
	}

	if (g_log_commands->value < 2) {
		string cmd = toLowerCase(CMD_ARGV(0));

		if (g_cmd_log_filter.find(cmd) != g_cmd_log_filter.end()) {
			return;
		}
		if (cmd.find("weapon_") == 0) {
			return;
		}
	}

	const char* steamid = getPlayerUniqueId(plr);
	logln("[Cmd][%s][%s] %s", steamid, STRING(plr->v.netname), command.c_str());
}

void ClientCommand(edict_t* pEntity) {
	META_RES ret = doCommand(pEntity) ? MRES_SUPERCEDE : MRES_IGNORED;

	if (g_log_commands->value > 0) {
		logClientCommand(pEntity);
	}

	RETURN_META(ret);
}

void log_speedhack(PlayerDat& dat, uint64_t now, int player_index) {
	bool didSpeedhack = dat.fastDetections + dat.slowDetections > 0;

	if (didSpeedhack) {
		if (dat.detectStartTime == 0) {
			dat.detectStartTime = now;
		}

		bool speedhackIsVeryLong = TimeDifference(dat.detectStartTime, now) > MAX_SPEEDHACK_DURATION;
		bool speedhackHasEnded = TimeDifference(dat.lastCorrection, now) > MIN_SPEEDHACK_DURATION;
		bool canLogNow = TimeDifference(dat.lastLogEvent, now) > MIN_SPEEDHACK_LOG_DELAY_SECONDS;

		if ((speedhackHasEnded || speedhackIsVeryLong) && canLogNow) {
			edict_t* plr = INDEXENT(player_index + 1);
			const char* steamid = getPlayerUniqueId(plr);
			float duration = TimeDifference(dat.detectStartTime, dat.lastCorrection);

			// not calling it a speedhack because lag spikes trigger this too
			logln("[AntiCheat] Throttled %s (%s) by %dms over %.2fs", 
				STRING(plr->v.netname), steamid,
				dat.fastDetections > 0 ? dat.fastDetections : -dat.slowDetections,
				duration);

			dat.fastDetections = 0;
			dat.slowDetections = 0;
			dat.lastLogEvent = now;
			dat.detectStartTime = 0;
		}
	}
}

// called before movement code runs, to check button presses and set initial values
void kill_jumpbug_cheaters_phase1(playermove_s* ppmove, edict_t* plr, PlayerDat& dat) {
	dat.lastHealth = plr->v.health;
	dat.lastVelocityZ = ppmove->velocity.z;
	dat.jumpedInstantlyAfterLanding = false;
	dat.jumpOrDuckButtonsChanged = ((ppmove->oldbuttons ^ ppmove->cmd.buttons) & (IN_JUMP | IN_DUCK)) != 0;
}

// called after movement code, to detect if player jumped instantly after landing
void kill_jumpbug_cheaters_phase2(playermove_s* ppmove, edict_t* plr, PlayerDat& dat) {
	dat.jumpedInstantlyAfterLanding = dat.lastVelocityZ < -JUMPBUG_SPEED && ppmove->velocity.z > 128;
}

// called after PostThink, to check if player avoided damage
void kill_jumpbug_cheaters_phase3(edict_t* plr, PlayerDat& dat) {
	bool preventedDamage = plr->v.health == dat.lastHealth && plr->v.waterlevel == 0 && plr->v.takedamage != DAMAGE_NO;

	if (dat.jumpedInstantlyAfterLanding && dat.jumpOrDuckButtonsChanged && preventedDamage) {
		if (g_engfuncs.pfnCVarGetFloat("mp_falldamage") == -1) {
			return; // not cheating if fall damage is disabled
		}
		
		TraceResult tr;
		int hullType = (plr->v.flags & FL_DUCKING) != 0 ? head_hull : human_hull;
		Vector traceEnd = plr->v.origin;
		traceEnd.z -= 8;

		g_engfuncs.pfnTraceHull(plr->v.origin, traceEnd, dont_ignore_monsters, hullType, plr, &tr);

		// you take no fall damage when landing into an updward slope at high speed. Instead you slide up it.
		bool launchingOffRamp = tr.vecPlaneNormal.z != 1 && tr.flFraction < 0.01f;

		// touching or slightly above ground?
		if (tr.flFraction < 1.0f && !launchingOffRamp) {
			logln("[AntiCheat] begin jumpbug kill code");
			const char* steamid = getPlayerUniqueId(plr);
			Vector origin = plr->v.origin;

			logln("[AntiCheat] Jumpbug on %s (%s): map=%s, origin=%d %d %d",
				STRING(plr->v.netname), steamid, STRING(gpGlobals->mapname), (int)origin.x, (int)origin.y, (int)origin.z);

			if (g_jumpbugCheck->value != 0) {
				logln("[AntiCheat] jumpbug message code");
				ClientPrintAll(HUD_PRINTNOTIFY, UTIL_VarArgs("[AntiCheat] %s was killed for using the jumpbug cheat.\n", STRING(plr->v.netname)));
				logln("[AntiCheat] jumpbug kill code");
				gpGamedllFuncs->dllapi_table->pfnClientKill(plr);
				logln("[AntiCheat] jumpbug kill done");
			}
		}
	}
}

void PlayerPreThink(edict_t* plr) {
	if (g_enabled->value > 0 && g_maxErrorSeconds->value > 0 && playerDat[ENTINDEX(plr) - 1].speedhackState == SPEEDHACK_FAST) {
		// not sure what this prevents but better safe than sorry
		RETURN_META(MRES_SUPERCEDE);
	}

	RETURN_META(MRES_OVERRIDE);
}

void PlayerPostThink(edict_t* plr) {
	if (g_enabled->value > 0 && g_maxErrorSeconds->value > 0 && playerDat[ENTINDEX(plr) - 1].speedhackState == SPEEDHACK_FAST) {
		// prevent weapon speedhack
		RETURN_META(MRES_SUPERCEDE);
	}

	RETURN_META(MRES_IGNORED);
}

void PlayerPostThink_post(edict_t* plr) {
	PlayerDat& dat = playerDat[ENTINDEX(plr) - 1];

	kill_jumpbug_cheaters_phase3(plr, dat);
	RETURN_META(MRES_IGNORED);
}

void PM_Move(playermove_s* ppmove, int server) {
	if (g_maxErrorSeconds->value == 0) {
		RETURN_META(MRES_IGNORED);
	}

	usercmd_t* cmd = &ppmove->cmd;
	edict_t* plr = INDEXENT(ppmove->player_index + 1);
	PlayerDat& dat = playerDat[ppmove->player_index];
	uint64_t now = getEpochMillis();

	if (plr->v.flags & FL_FROZEN) {
		// frozen players don't send normal command packets
		dat.msecTime = now;
		dat.speedhackState = SPEEDHACK_NOT;
		RETURN_META(MRES_IGNORED);
	}

	if (dat.msecTime == 0) {
		// start tracking a newly joined player
		dat.msecTime = now;
		dat.lastCmd = now;
	}	

	// accumulate time from command packets. Ideally it adds up to equal the server time.
	dat.msecTime += cmd->msec;

	// how far off is the client's clock from the server's clock?
	int error = TimeDifference(now, dat.msecTime) * 1000.0f;
	int maxErrorMs = g_maxErrorSeconds->value / 2; // cvar is max lag time, this is for +/- error ms

	const char* hackState = "none";

	if (error > maxErrorMs) {
		// commands are faster than normal
		dat.speedhackState = SPEEDHACK_FAST;
		hackState = "SPEEDHACK FAST";

		// this command will be ignored so that the player moves slower. Don't accumulate time from it
		dat.msecTime -= cmd->msec;
		dat.lastCorrection = now;
		dat.slowhackStart = 0;
		dat.fastDetections += cmd->msec;
	}
	else if (error < -maxErrorMs) {
		// commands are slower than normal.
		uint64_t windowMin = now - (uint64_t)maxErrorMs;// shift time just enough to be within the window of acceptable clock differences
		float diff2 = TimeDifference(dat.msecTime, windowMin);

		hackState = "slow (could be lag)";

		if (dat.slowhackStart == 0) {
			dat.slowhackStart = now;
		}

		if (TimeDifference(dat.slowhackStart, now)*1000 > maxErrorMs*2) {
			// player is consistently moving too slow. Speed them up.
			// The advantage you have with slow motion is delaying fall damage in survival mode
			hackState = "SPEEDHACK SLOW";

			// this command will be extended so that the player moves faster
			dat.msecTime -= cmd->msec;
			if (g_enabled->value > 0) {
				cmd->msec = min(255, (int)(diff2 * 1000));
			}
			dat.msecTime += cmd->msec;

			dat.speedhackState = SPEEDHACK_SLOW;
			dat.slowDetections += cmd->msec;
			dat.lastCorrection = now;
		}
		else {
			// player might be charging up to do a speed hack burst. Don't let them charge too long.
			if (dat.msecTime < windowMin) {
				dat.msecTime = windowMin;
			}
		}
	}
	else {
		dat.speedhackState = SPEEDHACK_NOT;
		dat.slowhackStart = 0;
	}

	float timeSinceLastPacket = TimeDifference(dat.lastCmd, getEpochMillis());
	dat.lastCmd = now;
	dat.packetCount++;

	// debug info
	/*
	//if (TimeDifference(dat.lastCorrection, now) < 0.5f)
	println("[AntiCheat] %s: error=%d (+/-%d), msec=%d, hack=%s", STRING(plr->v.netname), error, maxErrorMs, (int)cmd->msec, hackState);
	*/

	log_speedhack(dat, now, ppmove->player_index);	

	if (dat.speedhackState != SPEEDHACK_FAST) {
		kill_jumpbug_cheaters_phase1(ppmove, plr, dat);
	}

	if (g_enabled->value > 0 && dat.speedhackState == SPEEDHACK_FAST) {
		// prevent movement speedhack
		RETURN_META(MRES_SUPERCEDE);
	}

	RETURN_META(MRES_IGNORED);
}

void PM_Move_post(struct playermove_s* ppmove, int server) {
	edict_t* plr = INDEXENT(ppmove->player_index + 1);
	PlayerDat& dat = playerDat[ppmove->player_index];

	kill_jumpbug_cheaters_phase2(ppmove, plr, dat);
	RETURN_META(MRES_IGNORED);
}

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
int checkType = 0;

void StartFrame() {
	check_debuggers();

	uint64_t now = getEpochMillis();
	if (TimeDifference(lastCheck, now) < 60.0f) {
		RETURN_META(MRES_IGNORED);
	}

	lastCheck = now;
	checkType++;

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		if (checkType % 2 == 0) {
			(*g_engfuncs.pfnQueryClientCvarValue2)(plr, "sc_speedhack", 1337);
		}
		else {
			(*g_engfuncs.pfnQueryClientCvarValue2)(plr, "sc_speedhack_ltfx", 1337);
		}		
	}
	RETURN_META(MRES_IGNORED);
}
