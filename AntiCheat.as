
const float MOVEMENT_HACK_RATIO_FAST = 1.1f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_RATIO_SLOW = 0.5f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_MIN = 96; // min movement speed before detecting speedhack (detection inaccurate at low values)
const int HACK_DETECTION_MAX = 30; // max number of detections before killing player (expect some false positives)
const int MAX_CMDS_PER_SECOND = 220; // max number of commands/sec before it's speedhacking (200 max FPS + some buffer)
const float WEAPON_COOLDOWN_EPSILON = 0.05f; // allow this much error in cooldown time
const float JUMPBUG_SPEED = 580; // fall speed to detect jump bug (min amount for damage)
const float MAX_WEAPON_SPEEDUP = 1.3f; // max allowed speedhack on weapons (too low might kill innocent players)
const float WEAPON_ANALYZE_TIME = 1.5f; // minimum continous shooting time to detect hacking
const float MIN_BULLET_DELAY = 0.05f; // little faster than the fastest shooting weapon
const int BULLET_HISTORY_SIZE = (WEAPON_ANALYZE_TIME / MIN_BULLET_DELAY);
const int MOVEMENT_HISTORY_SIZE = 10; // bigger = better lag tolerance, but short speedhacks are undetected
const float LAGOUT_TIME = 0.3f; // pause speedhack checks if there's a gap in player commands longer than this
const float LAGOUT_GRACE_PERIOD = 0.1f; // time to pause speedhack checks after lag spike.

CCVar@ g_enable;
CCVar@ g_killPenalty;

dictionary g_speedhackPrimaryTime; // weapon primary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackSecondaryTime; // weapon secondary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackMinBullets; // min bullets to analyze for being too fast (too low and laggy players get killed)

array<SpeedState> g_speedStates(g_Engine.maxClients + 1);

bool g_enabled = false;
bool g_loaded_enable_setting = false;

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
	
	g_Hooks.RegisterHook( Hooks::Player::PlayerUse, @PlayerUse );
	
	g_Scheduler.SetInterval("detect_speedhack", 0.05f, -1);
	g_Scheduler.SetInterval("detect_jumpbug", 0.0f, -1);
	
	@g_enable = CCVar("enable", 1, "Toggle anticheat", ConCommandFlag::AdminOnly);
	@g_killPenalty = CCVar("kill_penalty", 6, "respawn delay for killed speedhackers", ConCommandFlag::AdminOnly);
	
	MapStart();
}

void MapStart() {
	CBasePlayerWeapon@ mp5 = cast<CBasePlayerWeapon@>(g_EntityFuncs.CreateEntity("weapon_9mmAR", null, true));
	bool isClassicMap = mp5.iMaxClip() == 50;
	g_EntityFuncs.Remove(mp5);

	g_speedhackPrimaryTime["weapon_9mmhandgun"] = 0.21; // longer for primary
	g_speedhackPrimaryTime["weapon_eagle"] = 0.305;
	g_speedhackPrimaryTime["weapon_uzi"] = 0.076;
	g_speedhackPrimaryTime["weapon_357"] = 0.75;
	g_speedhackPrimaryTime["weapon_9mmAR"] = 0.104;
	g_speedhackPrimaryTime["weapon_shotgun"] = 0.95;
	g_speedhackPrimaryTime["weapon_crossbow"] = 1.55;
	g_speedhackPrimaryTime["weapon_rpg"] = 2.0;
	g_speedhackPrimaryTime["weapon_gauss"] = 0.2;
	g_speedhackPrimaryTime["weapon_hornetgun"] = 0.104;
	g_speedhackPrimaryTime["weapon_handgrenade"] = 1.0;
	g_speedhackPrimaryTime["weapon_satchel"] = 0.5;
	g_speedhackPrimaryTime["weapon_sniperrifle"] = 1.8;
	g_speedhackPrimaryTime["weapon_m249"] = 0.083;
	g_speedhackPrimaryTime["weapon_sporelauncher"] = 0.6;
	g_speedhackPrimaryTime["weapon_minigun"] = 0.06;
	g_speedhackPrimaryTime["weapon_shockrifle"] = 0.08; // 0.22 for primary
	g_speedhackPrimaryTime["weapon_medkit"] = 0.5; //
	g_speedhackPrimaryTime["weapon_displacer"] = 2.0;
	g_speedhackPrimaryTime["weapon_tripmine"] = 0.305;
	g_speedhackPrimaryTime["weapon_snark"] = 0.305;
	g_speedhackPrimaryTime["weapon_crowbar"] = 0.25;
	g_speedhackPrimaryTime["weapon_pipewrench"] = 0.58;
	g_speedhackPrimaryTime["weapon_grapple"] = 0.5;
	g_speedhackPrimaryTime["weapon_m16"] = 0.168;
	
	g_speedhackSecondaryTime["weapon_9mmAR"] = 1.0; // false positive when doing m2 after m1
	g_speedhackSecondaryTime["weapon_m16"] = 2.3;
	
	if (!isClassicMap) {
		g_speedhackPrimaryTime["weapon_9mmhandgun"] = 0.175;
		g_speedhackPrimaryTime["weapon_shotgun"] = 0.255;
		g_speedhackPrimaryTime["weapon_9mmAR"] = 0.09;
	}
	
	if (!g_loaded_enable_setting) {
		g_enabled = g_enable.GetInt() != 0;
		g_loaded_enable_setting = true;
	}
	
	g_speedStates.resize(0);
	g_speedStates.resize(g_Engine.maxClients + 1);
}

class SpeedState {
	int detections; // number of times speedhack detections (many false positives with bad connection)
	float lastDetectTime;
	Vector lastOrigin;
	Vector lastVelocity;
	float lastHealth;
	int lastWepId = -1;

	array<float> lastSpeeds;
	array<float> lastExpectedSpeeds;
	array<float> lastPrimaryShootTimes;
	array<float> lastSecondaryShootTimes;
	
	float lastPrimaryClip;
	float lastPrimaryAmmo;
	float lastSecondaryAmmo;
	float lastNextPrimaryAttack;
	float lastPacket;
	float waitHackCheck; // wait before checking speedhack because player was lagged for a moment
	bool wasWaiting = false;
	
	SpeedState() {}
}

uint32 getPlayerBit(CBaseEntity@ plr) {
	return (1 << (plr.entindex() & 31));
}

void detect_speedhack() {
	if (!g_enabled) {
		return;
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected() or !plr.IsAlive()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		
		if (state.waitHackCheck > g_Engine.time) {
			continue;
		}
		
		float timeSinceLastCheck = g_Engine.time - state.lastDetectTime;
		state.lastDetectTime = g_Engine.time;
		
		int sussyMovement = detect_movement_speedhack(state, plr, timeSinceLastCheck);
		
		if (sussyMovement > 0) {
			state.detections += sussyMovement;
		}
		else if (state.detections > 0) {
			state.detections -= 1;
		}
		
		//println("SPEEDHACK: " + state.detections + " (+" + sussyMovement + ")");
		
		if (state.detections > HACK_DETECTION_MAX && plr.IsAlive()) {
			{	// log to file for debugging false positives
				string wepName = "(no wep)";
				CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());
				if (wep !is null) {
					wepName = wep.pev.classname;
				}
				
				string debugStr = "[AntiCheat] Killed " + plr.pev.netname + " at " + plr.pev.origin.ToString() + " for ("
							+ sussyMovement + " " + plr.pev.velocity.Length() + ") " + "\n";
				g_Log.PrintF(debugStr);
			}
			
			state.detections = 0;
			
			kill_hacker(state, plr, "speedhacking");
		}
	}
}

void kill_hacker(SpeedState@ state, CBasePlayer@ plr, string reason) {
	plr.Killed(g_EntityFuncs.Instance( 0 ).pev, GIB_ALWAYS);
	float defaultRespawnDelay = g_EngineFuncs.CVarGetFloat("mp_respawndelay");
	plr.m_flRespawnDelayTime = Math.max(g_killPenalty.GetInt(), defaultRespawnDelay) - defaultRespawnDelay;
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "[AntiCheat] " + plr.pev.netname + " was killed for " + reason + ".\n");
}

void detect_jumpbug() {
	if (!g_enabled) {
		return;
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected() or !plr.IsAlive()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		bool jumpedInstantlyAfterLanding = state.lastVelocity.z < -JUMPBUG_SPEED and plr.pev.velocity.z > 128;
		bool perfectlyTimedJump = plr.m_afButtonPressed & (IN_JUMP | IN_DUCK) != 0;
		bool preventedDamage = plr.pev.health == state.lastHealth;
		
		if (jumpedInstantlyAfterLanding and perfectlyTimedJump and preventedDamage) {
			{	// log to file for debugging false positives
				string debugStr = "[AntiCheat] Killed " + plr.pev.netname + " for jumpbug (" + state.lastVelocity.z + " " + plr.pev.velocity.z + " " + plr.m_afButtonPressed + ")\n";
				g_Log.PrintF(debugStr);
			}
		
			kill_hacker(state, plr, "using the jumpbug cheat");
		}
		
		state.lastVelocity = plr.pev.velocity;
		state.lastHealth = plr.pev.health;
	}
}

// returns how extreme the speed difference in (1 = minor, 2+ major)
int detect_movement_speedhack(SpeedState@ state, CBasePlayer@ plr, float timeSinceLastCheck) {
	if (plr.pev.movetype == MOVETYPE_NOCLIP or plr.m_afPhysicsFlags & PFLAG_ONBARNACLE != 0) {
		return 0;
	}

	Vector originDiff = plr.pev.origin - state.lastOrigin;
	
	// going up/down slopes makes velocity appear faster than it is
	originDiff.z = 0;
	
	Vector expectedVelocity = plr.pev.velocity + plr.pev.basevelocity;
	if (plr.pev.FlagBitSet(FL_ONGROUND) && plr.pev.groundentity !is null) {
		CBaseEntity@ pTrain = g_EntityFuncs.Instance( plr.pev.groundentity );
		
		if (pTrain is null or pTrain.pev.avelocity.Length() >= 1) {
			return 0; // too complicated to calculate where the player is expected to be
		}
		
		expectedVelocity = expectedVelocity + pTrain.pev.velocity;
	}
	
	float expectedSpeed = (expectedVelocity).Length();
	float actualSpeed = originDiff.Length() * (1.0f / timeSinceLastCheck);
	state.lastOrigin = plr.pev.origin;
	
	state.lastSpeeds.insertLast(actualSpeed);
	state.lastExpectedSpeeds.insertLast(expectedSpeed);
	
	if (state.lastSpeeds.size() > MOVEMENT_HISTORY_SIZE) {
		state.lastSpeeds.removeAt(0);
		state.lastExpectedSpeeds.removeAt(0);
	}
	
	float avgActual = 0;
	float avgExpected = 0;
	for (uint i = 0; i < state.lastSpeeds.size(); i++) {
		if (state.lastSpeeds[i] > state.lastExpectedSpeeds[i]*50) {
			// ignore super insane speed (teleport, most likely)
			//println("IGNORE INSANE SPEED (teleport)");
			continue;
		}
	
		avgActual += state.lastSpeeds[i];
		avgExpected += state.lastExpectedSpeeds[i];
	}
	avgActual /= float(state.lastSpeeds.size());
	avgExpected /= float(state.lastSpeeds.size());
	
	//println("SPEED: " + int(avgActual) + " / " + int(avgExpected));
	
	if (avgExpected == 0) {
		return 0;
	}
	
	float errorRatio = avgActual / avgExpected;
	bool isSpeedWrong = avgActual > MOVEMENT_HACK_MIN
			&& (avgActual > avgExpected*MOVEMENT_HACK_RATIO_FAST || avgActual < avgExpected*MOVEMENT_HACK_RATIO_SLOW);
	
	//println("ERROR RATIO: " + errorRatio);
	
	if (!isSpeedWrong) {
		return 0;
	}
	
	// being pushed by entities doesn't update velocity, so allow faster movement around moving ents
	Vector start = plr.pev.origin;
	for (uint i = 0; i < g_testDirs.size(); i++) {
		TraceResult tr;		
		g_Utility.TraceHull( start, start + g_testDirs[i], ignore_monsters, human_hull, plr.edict(), tr );
		CBaseEntity@ pHit = g_EntityFuncs.Instance( tr.pHit );
		if (pHit !is null and (pHit.pev.velocity.Length() > 1 or pHit.pev.avelocity.Length() > 1)) {
			return 0;
		}
	}
	
	int sussyness = 1;
	
	if (errorRatio > 2 || errorRatio < 0.25f) {
		sussyness = 2;
	} else if (errorRatio > 4 || errorRatio < 0.125f) {
		sussyness = 3;
	} else if (errorRatio > 8 || errorRatio < 0.05f) {
		sussyness = 4;
	}
	
	return sussyness;
}

float lastAttack = 0;

int getPrimaryAmmo(CBasePlayer@ plr, CBasePlayerWeapon@ wep) {
	return wep.m_iPrimaryAmmoType > -1 ? plr.m_rgAmmo(wep.m_iPrimaryAmmoType) : 0;
}

int getSecondaryAmmo(CBasePlayer@ plr, CBasePlayerWeapon@ wep) {
	return wep.m_iSecondaryAmmoType > -1 ? plr.m_rgAmmo(wep.m_iSecondaryAmmoType) : 0;
}

bool isMelee(CBasePlayerWeapon@ wep) {
	return wep.pev.classname == "weapon_crowbar" or wep.pev.classname == "weapon_pipewrench" or wep.pev.classname == "weapon_grapple";
}

// called after weapon shoot code
HookReturnCode PlayerUse( CBasePlayer@ plr, uint& out uiFlags ) {
	if (!g_enabled) {
		return HOOK_CONTINUE;
	}

	SpeedState@ state = g_speedStates[plr.entindex()];	
	
	// Detect if weapons are being shot too quickly
	CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());
	
	if (wep !is null) {
		// primary fired
		bool lessPrimaryAmmo = state.lastPrimaryAmmo > 0 && state.lastPrimaryAmmo > getPrimaryAmmo(plr, wep);
		bool lessSecondaryAmmo = state.lastSecondaryAmmo > 0 && state.lastSecondaryAmmo > getSecondaryAmmo(plr, wep);
		bool lessPrimaryClip = state.lastPrimaryClip > wep.m_iClip;
		bool wasReload = wep.m_iClip > state.lastPrimaryClip;
		bool meleeAttacked = wep.m_flNextPrimaryAttack != state.lastNextPrimaryAttack and isMelee(wep);
		float timeSinceLastCheck = g_Engine.time - state.lastPacket;
		
		if (timeSinceLastCheck > LAGOUT_TIME) {
			// got disconnected for a moment
			//println("DISCONNECTED FOR A MMOMENT " + timeSinceLastCheck);
			state.waitHackCheck = g_Engine.time + LAGOUT_GRACE_PERIOD; // a huge batch of packets is probably coming. Ignore it.
		}
		
		state.lastPrimaryClip = wep.m_iClip;
		state.lastPrimaryAmmo = getPrimaryAmmo(plr, wep);
		state.lastSecondaryAmmo = getSecondaryAmmo(plr, wep);
		state.lastNextPrimaryAttack = wep.m_flNextPrimaryAttack;
		state.lastPacket = g_Engine.time;
		
		if (state.waitHackCheck > g_Engine.time) {
			state.wasWaiting = true;
			return HOOK_CONTINUE;
		}
		
		if (state.wasWaiting) {
			//println("Resume hax check");
			state.wasWaiting = false;
		}
		
		if (wep.entindex() != state.lastWepId) {
			state.lastWepId = wep.entindex();
			state.lastPrimaryShootTimes.resize(0);
			state.lastSecondaryShootTimes.resize(0);
			return HOOK_CONTINUE;
		}
		
		float cooldown = 0;
		array<float>@ bulletTimes = null;
		
		// primary fired?
		if ((lessPrimaryAmmo || lessPrimaryClip || meleeAttacked) && !wasReload && g_speedhackPrimaryTime.exists(wep.pev.classname)) {
			g_speedhackPrimaryTime.get(wep.pev.classname, cooldown);
			@bulletTimes = state.lastPrimaryShootTimes;
		}
		
		// secondary fired?
		if (lessSecondaryAmmo && g_speedhackSecondaryTime.exists(wep.pev.classname)) {
			g_speedhackSecondaryTime.get(wep.pev.classname, cooldown);
			@bulletTimes = state.lastSecondaryShootTimes;
		}
		
		if (bulletTimes !is null) {
			bulletTimes.insertLast(g_Engine.time);
			if (bulletTimes.size() > BULLET_HISTORY_SIZE) {
				bulletTimes.removeAt(0);
			}
			
			uint bulletsToAnalyze = int(Math.max(3, (WEAPON_ANALYZE_TIME / cooldown) + 0.5f));
			
			if (wep.pev.classname == "weapon_m16") {
				bulletsToAnalyze = 7;
			}
			
			if (bulletTimes.size() >= bulletsToAnalyze) {
				float expectedDelta = (bulletsToAnalyze-1)*cooldown;
				float firstBulletTime = bulletTimes[bulletTimes.size() - bulletsToAnalyze];
				float actualDelta = g_Engine.time - firstBulletTime;
				float speedError = actualDelta != 0 ? (expectedDelta / actualDelta) : 99999;
				
				string debugMsg = "" + wep.pev.classname + " Bullets: " + bulletsToAnalyze + ", Cooldown: " + cooldown + ", Error: " + speedError;
				println(debugMsg);
			
				if (speedError > MAX_WEAPON_SPEEDUP) {
					println("ZOMG HACKING");
					
					g_Log.PrintF("[AntiCheat] Speedhack on " + plr.pev.netname + " " +debugMsg + "\n");
					kill_hacker(state, plr, "speedhacking");
				}
			}			
		}
	}
	
	
	return HOOK_CONTINUE;
}


CClientCommand _anticheat("anticheat", "AntiCheat", @anticheatToggle );

void anticheatToggle( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	g_enabled = !g_enabled;
	
	g_PlayerFuncs.SayText(plr, "[AntiCheat] " + (g_enabled ? "Enabled." : "Disabled."));
}