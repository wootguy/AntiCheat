
const float MOVEMENT_HACK_RATIO_FAST = 1.1f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_RATIO_SLOW = 0.5f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_MIN = 96; // min movement speed before detecting speedhack (detection inaccurate at low values)
const int HACK_DETECTION_MAX = 20; // max number of detections before killing player (expect some false positives)
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
const int REPLAY_HISTORY_SIZE = 1024; // number of packets to remember per player, for debugging speedhack detections
const string REPLAY_ROOT_PATH = "scripts/plugins/store/anticheat_replay/";

CCVar@ g_enable;
CCVar@ g_killPenalty;

dictionary g_speedhackPrimaryTime; // weapon primary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackSecondaryTime; // weapon secondary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackMinBullets; // min bullets to analyze for being too fast (too low and laggy players get killed)
dictionary g_weaponIds;

array<SpeedState> g_speedStates(g_Engine.maxClients + 1);

EHandle g_replay_ghost;

bool g_enabled = false;
bool g_loaded_enable_setting = false;
bool g_debug_mode = false;

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
	
	g_Scheduler.SetInterval("detect_speedhack", 0.05f, -1);
	g_Scheduler.SetInterval("detect_jumpbug", 0.0f, -1);
	
	@g_enable = CCVar("enable", 1, "Toggle anticheat", ConCommandFlag::AdminOnly);
	@g_killPenalty = CCVar("kill_penalty", 6, "respawn delay for killed speedhackers", ConCommandFlag::AdminOnly);
	
	MapStart();
}

void PluginExit() {
	g_EntityFuncs.Remove(g_replay_ghost);
}

void MapStart() {
	if (g_debug_mode)
		g_CustomEntityFuncs.RegisterCustomEntity( "monster_ghost", "monster_ghost" );
	
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
	g_speedhackPrimaryTime["weapon_m16"] = 0.168;
	
	// melee weapons can't be speedhacked
	
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
	
	g_weaponIds["weapon_9mmhandgun"] = 1; // longer for primary
	g_weaponIds["weapon_eagle"] = 2;
	g_weaponIds["weapon_uzi"] = 3;
	g_weaponIds["weapon_357"] = 4;
	g_weaponIds["weapon_9mmAR"] = 5;
	g_weaponIds["weapon_shotgun"] = 6;
	g_weaponIds["weapon_crossbow"] = 7;
	g_weaponIds["weapon_rpg"] = 8;
	g_weaponIds["weapon_gauss"] = 9;
	g_weaponIds["weapon_hornetgun"] = 10;
	g_weaponIds["weapon_handgrenade"] = 11;
	g_weaponIds["weapon_satchel"] = 12;
	g_weaponIds["weapon_sniperrifle"] = 13;
	g_weaponIds["weapon_m249"] = 14;
	g_weaponIds["weapon_sporelauncher"] = 15;
	g_weaponIds["weapon_minigun"] = 16;
	g_weaponIds["weapon_shockrifle"] = 17;
	g_weaponIds["weapon_medkit"] = 18;
	g_weaponIds["weapon_displacer"] = 19;
	g_weaponIds["weapon_tripmine"] = 20;
	g_weaponIds["weapon_snark"] = 21;
	g_weaponIds["weapon_m16"] = 22;
	
	g_speedStates.resize(0);
	g_speedStates.resize(g_Engine.maxClients + 1);
}

class PlayerFrame {
	float time;
	Vector origin;
	Vector velocity;
	Vector angles;
	uint32 buttons;
	float health;
	uint8 weaponId;
	uint8 weaponClip;
	uint16 weaponAmmo;
	uint16 weaponAmmo2;
	uint8 moveDetections; // number of movement hack detections
	
	PlayerFrame() {}
	
	PlayerFrame(CBasePlayer@ plr, CBasePlayerWeapon@ wep, SpeedState@ state) {
		this.time = g_Engine.time;
		this.origin = plr.pev.origin;
		this.velocity = plr.pev.velocity;
		this.angles = plr.pev.v_angle;
		this.buttons = plr.m_afButtonPressed | plr.m_afButtonLast;
		this.moveDetections = state.detections;
		this.health = plr.pev.health;
		
		if (wep !is null) {
			this.weaponClip = wep.m_iClip;
			this.weaponAmmo = getPrimaryAmmo(plr, wep);
			this.weaponAmmo2 = getSecondaryAmmo(plr, wep);
			g_weaponIds.get(wep.pev.classname, this.weaponId);
		} else {
			this.weaponId = 255;
		}
	}
	
	// load from file
	PlayerFrame(CBasePlayer@ plr, string line) {
		array<string> parts = line.Split("_");
		if (parts.size() != 11) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "[AntiCheat] Incompatible replay file.\n");
			return;
		}
		
		time = atof(parts[0]);
		g_Utility.StringToVector(origin, parts[1], ",");
		g_Utility.StringToVector(velocity, parts[2], ",");
		g_Utility.StringToVector(angles, parts[3], ",");
		buttons = atoi(parts[4]);
		health = atof(parts[5]);
		weaponId = atoi(parts[6]);
		weaponClip = atoi(parts[7]);
		weaponAmmo = atoi(parts[8]);
		weaponAmmo2 = atoi(parts[9]);
		moveDetections = atoi(parts[10]);
	}
	
	string toString() {
		return "" + time + "_" + origin.ToString() + "_" + velocity.ToString() + "_" + angles.ToString() + "_" 
				  + buttons + "_" + health + "_" + weaponId + "_" + weaponClip + "_" + weaponAmmo + "_" + weaponAmmo2 + "_" + moveDetections;
	}
}

class monster_ghost : ScriptBaseMonsterEntity
{	
	bool KeyValue( const string& in szKey, const string& in szValue )
	{
		return BaseClass.KeyValue( szKey, szValue );
	}
	
	void Spawn()
	{		
		pev.movetype = MOVETYPE_FLY;
		pev.solid = SOLID_NOT;
		
		g_EntityFuncs.SetModel(self, self.pev.model);		
		g_EntityFuncs.SetSize(self.pev, Vector( -16, -16, -36), Vector(16, 16, 36));
		g_EntityFuncs.SetOrigin( self, pev.origin);

		//SetThink( ThinkFunction( CustomThink ) );
		
		pev.takedamage = DAMAGE_NO;
		pev.health = 1;
		
		self.MonsterInit();
		
		self.m_MonsterState = MONSTERSTATE_NONE;
		
		self.m_IdealActivity = ACT_RELOAD;
		self.ClearSchedule();
	}
	
	Schedule@ GetSchedule( void )
	{
		// prevent default schedules changing the animation
		pev.nextthink = g_Engine.time + Math.max(0.1f, 0.1f);
		return BaseClass.GetScheduleOfType(SCHED_RELOAD);
	}
};

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
	array<PlayerFrame> replayHistory;
	
	float lastPrimaryClip;
	float lastPrimaryAmmo;
	float lastSecondaryAmmo;
	float lastPacket;
	float waitHackCheck; // wait before checking speedhack because player was lagged for a moment
	bool wasWaiting = false;
	
	SpeedState() {}
}

uint32 getPlayerBit(CBaseEntity@ plr) {
	return (1 << (plr.entindex() & 31));
}

void detect_speedhack() {
	//if (!g_enabled) {
	//	return;
	//}
	
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
	if (g_enabled) {
		plr.Killed(g_EntityFuncs.Instance( 0 ).pev, GIB_ALWAYS);
		float defaultRespawnDelay = g_EngineFuncs.CVarGetFloat("mp_respawndelay");
		plr.m_flRespawnDelayTime = Math.max(g_killPenalty.GetInt(), defaultRespawnDelay) - defaultRespawnDelay;
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "[AntiCheat] " + plr.pev.netname + " was killed for " + reason + ".\n");
	} else {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTCONSOLE, "[AntiCheat] " + plr.pev.netname + " " + reason + ".\n");
	}
	
	writeReplayData(state, plr);
	
	state.detections = 0;
	state.lastSpeeds.resize(0);
	state.lastExpectedSpeeds.resize(0);
	state.lastPrimaryShootTimes.resize(0);
	state.lastSecondaryShootTimes.resize(0);
	state.replayHistory.resize(0);
}

void writeReplayData(SpeedState@ state, CBasePlayer@ plr) {

	DateTime now = DateTime();
	string timeStr = "" + now.GetYear() + "-" + formatInt(now.GetMonth()+1, "0", 2) + "_" + formatInt(now.GetDayOfMonth()+1, "0", 2) + "_" + 
					 formatInt(now.GetHour()+1, "0", 2) + "-" + formatInt(now.GetMinutes()+1, "0", 2) + "-" + formatInt(now.GetSeconds()+1, "0", 2);
	string path = REPLAY_ROOT_PATH + timeStr + "__" + g_Engine.mapname + "__" + plr.pev.netname + ".txt";
	
	File@ f = g_FileSystem.OpenFile(path, OpenFile::WRITE);
	
	if (f is null or !f.IsOpen()) {
		g_Log.PrintF("[AntiCheat] Failed to open replay file for writing: " + path + "\n");
		return;
	}
	
	for (uint i = 0; i < state.replayHistory.size(); i++) {
		f.Write(state.replayHistory[i].toString() + "\n");
	}
	
	f.Close();
	
	float duration = g_Engine.time - state.replayHistory[0].time;
	
	g_Log.PrintF("[AntiCheat] Wrote " + duration + "s replay file: " + path + "\n");
}

void debug_replay(EHandle h_ghost, array<PlayerFrame>@ frames, float startTime, int startFrame, float speed, int lastFrame) {
	CBaseEntity@ ghost = h_ghost;
	
	if (ghost is null) {
		return;
	}
	
	float t = (g_Engine.time - startTime)*speed;
	if (t + frames[startFrame].time > frames[frames.size()-1].time + 1.0f*speed) { 
		startTime = g_Engine.time;
	}
	
	for (int i = int(frames.size())-1; i >= startFrame; i--) {
		if (t + frames[startFrame].time >= frames[i].time) {
			PlayerFrame@ frame = frames[i];
			ghost.pev.origin = frame.origin;
			ghost.pev.angles = frame.angles;
			
			if (i != lastFrame) {
				int nextFrameTime = i < int(frames.size())-1 ? int((frames[i+1].time - frame.time)*1000) : -1;
				println("Time: " + formatFloat(t, "", 6, 3)
						+ ", Frame " + formatInt(i, "", 3)
						+ ", Speed: " + formatInt(int(frame.velocity.Length()), "", 4)
						+ ", Buttons: " + formatInt(frame.buttons, "", 5)
						+ ", HP: " + formatInt(int(frame.health), "", 3)
						+ ", detections: " + formatInt(frame.moveDetections, "", 2)
						+ ", nextFrame: " + formatInt(nextFrameTime, "", 3) + "ms");
			}
			
			lastFrame = i;
			
			break;
		}
	}
	
	g_Scheduler.SetTimeout("debug_replay", 0.0f, h_ghost, @frames, startTime, startFrame, speed, lastFrame);
}

void detect_jumpbug() {
	//if (!g_enabled) {
	//	return;
	//}
	
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
	
	
	
	Vector expectedVelocity = plr.pev.velocity + plr.pev.basevelocity;
	if (plr.pev.FlagBitSet(FL_ONGROUND) && plr.pev.groundentity !is null) {
		CBaseEntity@ pTrain = g_EntityFuncs.Instance( plr.pev.groundentity );
		
		if (pTrain is null or pTrain.pev.avelocity.Length() >= 1) {
			return 0; // too complicated to calculate where the player is expected to be
		}
		
		expectedVelocity = expectedVelocity + pTrain.pev.velocity;
	}
	
	// going up/down slopes makes velocity appear faster than it is
	originDiff.z = 0;
	expectedVelocity.z = 0;
	
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
	} else if (errorRatio > 4 || errorRatio < 0.1f) {
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

// called after weapon shoot code
HookReturnCode PlayerPostThink(CBasePlayer@ plr) {
	//if (!g_enabled) {
	//	return HOOK_CONTINUE;
	//}

	SpeedState@ state = g_speedStates[plr.entindex()];	
	
	// Detect if weapons are being shot too quickly
	CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());
	
	state.replayHistory.insertLast(PlayerFrame(plr, wep, state));
	if (state.replayHistory.size() > REPLAY_HISTORY_SIZE) {
		state.replayHistory.removeAt(0);
	}
	
	if (wep !is null) {
		// primary fired
		bool lessPrimaryAmmo = state.lastPrimaryAmmo > 0 && state.lastPrimaryAmmo > getPrimaryAmmo(plr, wep);
		bool lessSecondaryAmmo = state.lastSecondaryAmmo > 0 && state.lastSecondaryAmmo > getSecondaryAmmo(plr, wep);
		bool lessPrimaryClip = state.lastPrimaryClip > wep.m_iClip;
		bool wasReload = wep.m_iClip > state.lastPrimaryClip;
		float timeSinceLastCheck = g_Engine.time - state.lastPacket;
		
		if (timeSinceLastCheck > LAGOUT_TIME) {
			// got disconnected for a moment
			//println("DISCONNECTED FOR A MMOMENT " + timeSinceLastCheck);
			state.waitHackCheck = g_Engine.time + LAGOUT_GRACE_PERIOD; // a huge batch of packets is probably coming. Ignore it.
		}
		
		state.lastPrimaryClip = wep.m_iClip;
		state.lastPrimaryAmmo = getPrimaryAmmo(plr, wep);
		state.lastSecondaryAmmo = getSecondaryAmmo(plr, wep);
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
		if ((lessPrimaryAmmo || lessPrimaryClip) && !wasReload && g_speedhackPrimaryTime.exists(wep.pev.classname)) {
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
CClientCommand _replay("replaycheat", "AntiCheat", @replayCheater );

void anticheatToggle( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	g_enabled = !g_enabled;
	
	g_PlayerFuncs.SayText(plr, "[AntiCheat] " + (g_enabled ? "Enabled." : "Disabled."));
}

void replayCheater( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	
	string path = REPLAY_ROOT_PATH + args[1];
	int frameOffset = atoi(args[2]);
	float speed = atof(args[3]);
	if (speed == 0)
		speed = 1;
		
	if (int(path.Find(".txt")) == -1) {
		path = path + ".txt";
	}
	
	println("REPLAY  " + path);
	
	File@ file = g_FileSystem.OpenFile(path, OpenFile::READ);
	
	if (file is null or !file.IsOpen()) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "[AntiCheat] replay file not found: " + path + "\n");
		return;
	}
	
	array<PlayerFrame> frames;
	
	while (!file.EOFReached()) {
		string line;
		file.ReadLine(line);
		
		if (line.IsEmpty()) {
			continue;
		}
		
		frames.insertLast(PlayerFrame(plr, line));
	}
	
	file.Close();	
	
	dictionary keys;
	keys["origin"] = frames[0].origin.ToString();
	keys["model"] = "models/player.mdl";
	keys["minhullsize"] = "-16 -16 -36";
	keys["maxhullsize"] = "16 16 36";
	//keys["rendermode"] = "2";
	//keys["renderamt"] = "255";
	//keys["targetname"] = ghostName; // NOTE: targetname causes animation glitches when spawned (schedule != RELOAD)
	CBaseEntity@ ent = g_EntityFuncs.CreateEntity(g_debug_mode ? "monster_ghost" : "env_model", keys, true);
	
	ent.pev.solid = SOLID_NOT;
	ent.pev.movetype = MOVETYPE_FLY;
	ent.pev.takedamage = 0;
	ent.pev.flags |= EF_NOINTERP;
	
	g_EntityFuncs.Remove(g_replay_ghost);
	g_replay_ghost = ent;
	
	plr.pev.origin = frames[frames.size()-1].origin;
	
	println("Start " + frames.size() + " replay from " + frames[0].time);
	g_Scheduler.SetTimeout("debug_replay", 0.5f, g_replay_ghost, frames, g_Engine.time, frameOffset, speed, -1);
}