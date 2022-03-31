
const float MOVEMENT_HACK_RATIO_FAST = 1.1f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_RATIO_SLOW = 0.9f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_MIN = 96; // min movement speed before detecting speedhack (detection inaccurate at low values)
const int HACK_DETECTION_MAX = 40; // max number of detections before killing player (expect some false positives)
const int MAX_CMDS_PER_SECOND = 220; // max number of commands/sec before it's speedhacking (200 max FPS + some buffer)
const float WEAPON_COOLDOWN_EPSILON = 0.05f; // allow this much error in cooldown time
const float JUMPBUG_SPEED = 580; // fall speed to detect jump bug (min amount for damage)

CCVar@ g_enable;
CCVar@ g_killPenalty;

dictionary g_speedhackPrimaryTime; // weapon primary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackSecondaryTime; // weapon secondary fires that are affected by speedhacking. Value is expected delay.

array<SpeedState> g_speedStates(g_Engine.maxClients + 1);

int g_playerPostThinkPrimaryClip = 0;
int g_playerPostThinkPrimaryAmmo = 0;
int g_playerPostThinkSecondaryAmmo = 0;

array<Vector> g_testDirs = {
	Vector(32, 0, 0),
	Vector(-32, 0, 0),
	Vector(0, 32, 0),
	Vector(0, -32, 0)
};

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook( Hooks::Player::PlayerPostThink, @PlayerPostThink );
	g_Hooks.RegisterHook( Hooks::Player::PlayerUse, @PlayerUse );
	
	g_Scheduler.SetInterval("detect_speedhack", 0.05f, -1);
	g_Scheduler.SetInterval("detect_jumpbug", 0.0f, -1);
	
	MapStart();
	
	@g_enable = CCVar("enable", 1, "Toggle anticheat", ConCommandFlag::AdminOnly);
	@g_killPenalty = CCVar("kill_penalty", 6, "respawn delay for killed speedhackers", ConCommandFlag::AdminOnly);
}

void MapStart() {
	CBaseEntity@ modernWeapon = g_EntityFuncs.CreateEntity("weapon_m16", null, true);
	bool isClassicMap = modernWeapon is null;
	g_EntityFuncs.Remove(modernWeapon);

	g_speedhackPrimaryTime["weapon_9mmhandgun"] = 0.2;
	g_speedhackPrimaryTime["weapon_eagle"] = 0.3;
	g_speedhackPrimaryTime["weapon_uzi"] = 0.08;
	g_speedhackPrimaryTime["weapon_357"] = 0.75;
	g_speedhackPrimaryTime["weapon_9mmAR"] = 0.1;
	g_speedhackPrimaryTime["weapon_shotgun"] = 0.95; // .75 when doing m2 after m1
	g_speedhackPrimaryTime["weapon_crossbow"] = 1.55;
	g_speedhackPrimaryTime["weapon_rpg"] = 2.0;
	g_speedhackPrimaryTime["weapon_gauss"] = 0.2;
	g_speedhackPrimaryTime["weapon_hornetgun"] = 0.1;
	g_speedhackPrimaryTime["weapon_handgrenade"] = 1.0;
	g_speedhackPrimaryTime["weapon_satchel"] = 0.5;
	g_speedhackPrimaryTime["weapon_sniperrifle"] = 1.8;
	g_speedhackPrimaryTime["weapon_m249"] = 0.08;
	g_speedhackPrimaryTime["weapon_sporelauncher"] = 0.6;
	
	g_speedhackSecondaryTime["weapon_9mmAR"] = 1.0; // false positive when doing m2 after m1
	
	if (!isClassicMap) {
		g_speedhackPrimaryTime["weapon_9mmhandgun"] = 0.16;
		g_speedhackPrimaryTime["weapon_shotgun"] = 0.25;
		g_speedhackPrimaryTime["weapon_m16"] = 0.07;
		g_speedhackSecondaryTime["weapon_m16"] = 2.3;
		g_speedhackPrimaryTime["weapon_9mmAR"] = 0.08;
	}
}

class SpeedState {
	float lastIdleTime;
	int detections; // number of times speedhack detections (many false positives with bad connection)
	int wepDetections; // number of weapon speedhack detections (added to detections later)
	float lastDetectTime;
	Vector lastOrigin;
	Vector lastVelocity;
	float nextAllowedAttack;

	array<float> lastSpeeds;
	array<float> lastExpectedSpeeds;
	
	SpeedState() {}
}

uint32 getPlayerBit(CBaseEntity@ plr) {
	return (1 << (plr.entindex() & 31));
}

void detect_speedhack() {
	if (g_enable.GetInt() == 0) {
		return;
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected() or !plr.IsAlive()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		float timeSinceLastCheck = g_Engine.time - state.lastDetectTime;
		state.lastDetectTime = g_Engine.time;
		
		bool isTooFast = detect_movement_speedhack(state, plr, timeSinceLastCheck);
		bool isWepTooFast = state.wepDetections > 0;
		
		if (isWepTooFast) {
			state.detections += state.wepDetections;
		}
		else if (isTooFast) {
			state.detections += 1;
		}
		else if (state.detections > 0) {
			state.detections -= 1;
		}
		
		//println("SPEEDHACK: " + state.detections + " (" + isTooFast + " " + state.wepDetections + ")");
		
		if (state.detections > HACK_DETECTION_MAX && plr.IsAlive()) {
			{	// log to file for debugging false positives
				string wepName = "(no wep)";
				CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());
				if (wep !is null) {
					wepName = wep.pev.classname;
				}
				
				string debugStr = "[AntiCheat] Killed " + plr.pev.netname + " at " + plr.pev.origin.ToString() + " for ("
							+ isTooFast + " " + plr.pev.velocity.ToString() + ") or (" + state.wepDetections + " " + wepName + ")" + g_Engine.time + "\n";
				g_Log.PrintF(debugStr);
			}
			
			state.detections = 0;
			
			kill_hacker(state, plr, "speedhacking");
		}
		
		state.wepDetections = 0;
	}
}

void kill_hacker(SpeedState@ state, CBasePlayer@ plr, string reason) {
	plr.Killed(g_EntityFuncs.Instance( 0 ).pev, GIB_ALWAYS);
	float defaultRespawnDelay = g_EngineFuncs.CVarGetFloat("mp_respawndelay");
	plr.m_flRespawnDelayTime = Math.max(g_killPenalty.GetInt(), defaultRespawnDelay) - defaultRespawnDelay;
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "[AntiCheat] " + plr.pev.netname + " was killed for " + reason + ".\n");
}

void detect_jumpbug() {
	if (g_enable.GetInt() == 0) {
		return;
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected() or !plr.IsAlive()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		
		if (state.lastVelocity.z < -JUMPBUG_SPEED and plr.pev.velocity.z > 0 and plr.m_afButtonPressed & (IN_JUMP | IN_DUCK) != 0) {
			{	// log to file for debugging false positives
				string debugStr = "[AntiCheat] Killed " + plr.pev.netname + " for jumpbug (" + state.lastVelocity.z + " " + plr.pev.velocity.z + " " + plr.m_afButtonPressed + ")\n";
				g_Log.PrintF(debugStr);
			}
		
			kill_hacker(state, plr, "using the jumpbug cheat");
		}
		
		state.lastVelocity = plr.pev.velocity;
	}
}

bool detect_movement_speedhack(SpeedState@ state, CBasePlayer@ plr, float timeSinceLastCheck) {
	if (plr.pev.movetype == MOVETYPE_NOCLIP or plr.m_afPhysicsFlags & PFLAG_ONBARNACLE != 0) {
		return false;
	}

	Vector originDiff = plr.pev.origin - state.lastOrigin;
	
	// going up/down slopes makes velocity appear faster than it is
	originDiff.z = 0;
	
	Vector expectedVelocity = plr.pev.velocity + plr.pev.basevelocity;
	if (plr.pev.FlagBitSet(FL_ONGROUND) && plr.pev.groundentity !is null) {
		CBaseEntity@ pTrain = g_EntityFuncs.Instance( plr.pev.groundentity );
		
		if (pTrain is null or pTrain.pev.avelocity.Length() >= 1) {
			return false; // too complicated to calculate where the player is expected to be
		}
		
		expectedVelocity = expectedVelocity + pTrain.pev.velocity;
	}
	
	float expectedSpeed = (expectedVelocity).Length();
	float actualSpeed = originDiff.Length() * (1.0f / timeSinceLastCheck);
	state.lastOrigin = plr.pev.origin;
	
	state.lastSpeeds.insertLast(actualSpeed);
	state.lastExpectedSpeeds.insertLast(expectedSpeed);
	
	if (state.lastSpeeds.size() > 3) {
		state.lastSpeeds.removeAt(0);
		state.lastExpectedSpeeds.removeAt(0);
	}
	
	float avgActual = 0;
	float avgExpected = 0;
	for (uint i = 0; i < state.lastSpeeds.size(); i++) {
		avgActual += state.lastSpeeds[i];
		avgExpected += state.lastExpectedSpeeds[i];
	}
	avgActual /= float(state.lastSpeeds.size());
	avgExpected /= float(state.lastSpeeds.size());
	
	//println("SPEED: " + int(avgActual) + " / " + int(avgExpected));
	
	bool isSpeedWrong = avgActual > MOVEMENT_HACK_MIN
			&& (avgActual > avgExpected*MOVEMENT_HACK_RATIO_FAST || avgActual < avgExpected*MOVEMENT_HACK_RATIO_SLOW);
	
	if (!isSpeedWrong) {
		return false;
	}
	
	// being pushed by entities doesn't update velocity, so allow faster movement around moving ents
	Vector start = plr.pev.origin;
	for (uint i = 0; i < g_testDirs.size(); i++) {
		TraceResult tr;		
		g_Utility.TraceHull( start, start + g_testDirs[i], ignore_monsters, human_hull, plr.edict(), tr );
		CBaseEntity@ pHit = g_EntityFuncs.Instance( tr.pHit );
		if (pHit !is null and (pHit.pev.velocity.Length() > 1 or pHit.pev.avelocity.Length() > 1)) {
			return false;
		}
	}
	
	return true;
}

// called before weapon shoot code
HookReturnCode PlayerPostThink(CBasePlayer@ plr) {	
	CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());
	
	if (wep !is null) {
		g_playerPostThinkPrimaryClip = wep.m_iClip;
		g_playerPostThinkPrimaryAmmo = wep.m_iPrimaryAmmoType != -1 ? plr.m_rgAmmo( wep.m_iPrimaryAmmoType ) : 0;
		g_playerPostThinkSecondaryAmmo = wep.m_iSecondaryAmmoType != -1 ? plr.m_rgAmmo( wep.m_iSecondaryAmmoType ) : 0;
	}
	
	return HOOK_CONTINUE;
}

float lastAttack = 0;

// called after weapon shoot code
HookReturnCode PlayerUse( CBasePlayer@ plr, uint& out uiFlags ) {
	SpeedState@ state = g_speedStates[plr.entindex()];	
	
	// Detect if weapons are being shot too quickly
	CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());
	
	if (wep !is null) {
		// primary fired
		bool lessPrimaryAmmo = g_playerPostThinkPrimaryAmmo > 0 && g_playerPostThinkPrimaryAmmo > plr.m_rgAmmo(wep.m_iPrimaryAmmoType);
		bool lessSecondaryAmmo = g_playerPostThinkSecondaryAmmo > 0 && g_playerPostThinkSecondaryAmmo > plr.m_rgAmmo(wep.m_iSecondaryAmmoType);
		bool lessPrimaryClip = g_playerPostThinkPrimaryClip > wep.m_iClip;
		bool wasReload = wep.m_iClip > g_playerPostThinkPrimaryClip;
		float cooldown = 0;
		
		if ((lessPrimaryAmmo || lessPrimaryClip) && !wasReload && g_speedhackPrimaryTime.exists(wep.pev.classname)) {
			//println("SHOT PRIMARY " + wep.m_flNextPrimaryAttack);
			g_speedhackPrimaryTime.get(wep.pev.classname, cooldown);
		}
		
		// secondary fired
		if (lessSecondaryAmmo && g_speedhackSecondaryTime.exists(wep.pev.classname)) {
			//println("SHOT SECONDARY " + wep.m_flNextSecondaryAttack);
			g_speedhackSecondaryTime.get(wep.pev.classname, cooldown);
		}
		
		if (cooldown > 0) {
			if (g_Engine.time + WEAPON_COOLDOWN_EPSILON < state.nextAllowedAttack) {
				int penalty = Math.min(10, int(cooldown*20));
				if (wep.pev.classname == "weapon_m16" && cooldown < 1) {
					penalty = 5;
				}
				
				state.wepDetections += penalty;
				
				//println("SPEEDHACK " + penalty);
				//g_Log.PrintF("[AntiCheat] Speedhack on " + plr.pev.netname + " " + wep.pev.classname + " " + lessPrimaryAmmo + " " + lessPrimaryClip + " " + wasReload + " " + lessSecondaryAmmo +  " " + g_Engine.time + "\n");
			}
			
			float diff = g_Engine.time - lastAttack;
			//println("DIFF: " + diff);
			
			state.nextAllowedAttack = g_Engine.time + cooldown;
			
			lastAttack = g_Engine.time;
		}
	}
	
	
	return HOOK_CONTINUE;
}
