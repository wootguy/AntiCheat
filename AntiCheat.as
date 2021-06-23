
const float MOVEMENT_HACK_RATIO = 1.1f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_MIN = 96; // min movement speed before detecting speedhack (detection inaccurate at low values)
const int HACK_DETECTION_MAX = 30; // max number of detections before killing player (expect some false positives)
const int MAX_CMDS_PER_SECOND = 220; // max number of commands/sec before it's speedhacking (200 max FPS + some buffer)

CCVar@ g_enable;
CCVar@ g_killPenalty;

dictionary g_speedhackPrimaryTime; // weapon primary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackSecondaryTime; // weapon secondary fires that are affected by speedhacking. Value is expected delay.

array<SpeedState> g_speedStates(g_Engine.maxClients + 1);

int g_playerPostThinkPrimaryClip = 0;
int g_playerPostThinkPrimaryAmmo = 0;
int g_playerPostThinkSecondaryAmmo = 0;

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook( Hooks::Player::PlayerPostThink, @PlayerPostThink );
	g_Hooks.RegisterHook( Hooks::Player::PlayerUse, @PlayerUse );
	
	g_Scheduler.SetInterval("detect_speedhack", 0.05f, -1);
	
	MapStart();
	
	@g_enable = CCVar("enable", 1, "Toggle anticheat", ConCommandFlag::AdminOnly);
	@g_killPenalty = CCVar("kill_penalty", 30, "respawn delay for killed speedhackers", ConCommandFlag::AdminOnly);
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
	float nextAllowedAttack;
	
	array<float> lastCmdCalls;
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
		
		bool isIdleTooFast = detect_weapon_idle_speedhack(state, plr, timeSinceLastCheck);
		bool isTooFast = detect_movement_speedhack(state, plr, timeSinceLastCheck);
		bool isTooManyCmds = state.lastCmdCalls.size() > MAX_CMDS_PER_SECOND;
		bool isWepTooFast = state.wepDetections > 0;
		
		if (isWepTooFast) {
			state.detections += state.wepDetections;
		}
		
		if (isTooFast || isTooManyCmds || isWepTooFast || isIdleTooFast) {
			state.detections += 1;
		} else if (state.detections > 0) {
			state.detections -= 1;
		}
		
		//println("SPEEDHACK: " + state.detections + " (" + isTooFast + " " + isTooManyCmds + " " + isIdleTooFast + " " + state.wepDetections + ")");
		
		if (state.detections > HACK_DETECTION_MAX && plr.IsAlive()) {
			plr.Killed(g_EntityFuncs.Instance( 0 ).pev, GIB_ALWAYS);
			float defaultRespawnDelay = g_EngineFuncs.CVarGetFloat("mp_respawndelay");
			plr.m_flRespawnDelayTime = Math.max(g_killPenalty.GetInt(), defaultRespawnDelay) - defaultRespawnDelay;
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "[VAC] " + plr.pev.netname + " was killed for speedhacking.\n");
			state.detections = 0;
		}
		
		state.wepDetections = 0;
	}
}

// weapon idle timers decrease faster when speed hacking.
// this only works above 1.5x speed and when certain weapons are equipped.
bool detect_weapon_idle_speedhack(SpeedState@ state, CBasePlayer@ plr, float timeSinceLastCheck) {
	CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());

	if (wep !is null && g_speedhackPrimaryTime.exists(wep.pev.classname)) {
		float idleDiff = state.lastIdleTime - wep.m_flTimeWeaponIdle;
		float error = int((idleDiff - timeSinceLastCheck)*1000);
		state.lastIdleTime = wep.m_flTimeWeaponIdle;
		
		// too low and fps_max 30 will start triggering without speedhack
		return error > 15;
	}
	
	return false;
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
		
		if (pTrain.pev.avelocity.Length() >= 1) {
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
	
	return avgActual > MOVEMENT_HACK_MIN && avgActual > avgExpected*MOVEMENT_HACK_RATIO;
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

	// More PlayerUse calls are made when speedhacking. Client FPS also affects PlayerUse count though.
	// The max client FPS is 200, so any more calls than that must mean the client is speedhacking.
	// This detects extreme speedhacks at 20 FPS (>11x) or mild speedhacks (1.1x) at 200 FPS
	
	state.lastCmdCalls.insertLast(g_EngineFuncs.Time());
	float cutoff = g_EngineFuncs.Time() - 1.0f;
	while (state.lastCmdCalls.size() > 0) {
		if (state.lastCmdCalls[0] < cutoff) {
			state.lastCmdCalls.removeAt(0);
		} else {
			break;
		}
	}
	
	
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
			if (g_Engine.time + 0.01f < state.nextAllowedAttack) {
				int penalty = Math.min(20, int(cooldown*20));
				state.wepDetections += penalty;
				
				if (wep.pev.classname == "weapon_m16" && cooldown < 1) {
					penalty = 5;
				}
				//println("SPEEDHACK " + penalty);
			}
			
			float diff = g_Engine.time - lastAttack;
			//println("DIFF: " + diff);
			
			state.nextAllowedAttack = g_Engine.time + cooldown;
			
			lastAttack = g_Engine.time;
		}
	}
	
	
	return HOOK_CONTINUE;
}
