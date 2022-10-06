#include "../inc/RelaySay"

// False positives:
// - stuck inside tentacle
// - portal spawner teleports
// - fm_fun slowing down on big slope while strafing into wall

// TODO:
// - pausing near pushing entities is overkill yet still triggers false positives
// - less tolerant for 1.4x weapon speedup over long durations, maybe go down to 1.1x
// - shock_rifle secondary speedhack ignored
// - can fire rpg faster if standing on ammo (weapon reloads when picking up ammo sometimes)

enum MODE {
	MODE_DISABLE, // disable all checks (for testing server lag)
	MODE_ENABLE,  // kill speedhackers
	MODE_OBSERVE  // detect cheats and write replay data but don't kill anyone
}

class IgnoreZone {
	Vector mins;
	Vector maxs;
	
	IgnoreZone() {}
	
	IgnoreZone(Vector mins, Vector maxs) {
		this.mins = mins;
		this.maxs = maxs;
	}
}

const float MOVEMENT_HACK_RATIO_FAST = 1.2f; // how much faster actual speed can be than expected
const float MOVEMENT_HACK_RATIO_SLOW = 0.8f; // how much slower actual speed can be than expected
const int HACK_DETECTION_MAX = 20; // max number of detections before killing player (expect some false positives)
const float JUMPBUG_SPEED = 580; // fall speed to detect jump bug (min speed for damage)
const float MAX_WEAPON_SPEEDUP = 1.3f; // how much faster actual weapon shoot speed than expected
const float WEAPON_ANALYZE_TIME = 1.5f; // minimum continous shooting time to detect hacking
const float MIN_BULLET_DELAY = 0.05f; // a little faster than the fastest shooting weapon
const int BULLET_HISTORY_SIZE = (WEAPON_ANALYZE_TIME / MIN_BULLET_DELAY);
const int MOVEMENT_HISTORY_SIZE = 10; // bigger = better lag tolerance, but short speedhacks are undetected
const float LAGOUT_TIME = 0.0667f; // pause speedhack checks if there's a gap in player commands longer than this (15fps)
const float LAGOUT_GRACE_PERIOD_MAX = 0.5f; // max time time to pause speedhack checks after lag spike.
const int REPLAY_HISTORY_SIZE = 1024; // number of packets to remember per player, for debugging speedhack detections
const int MOVE_DETECT_HISTORY_SIZE = 100; // number of packets to remember per player, for debugging speedhack detections
const string REPLAY_ROOT_PATH = "scripts/plugins/store/anticheat_replay/";
const float AFK_TIME = 5.0f; // min time to not be pressing buttons before speedhack checks are disabled
const float MOVING_OBJECT_PAUSE_TIME = 0.5f; // fix false postives when rubbing past or jumping off a moving platform
const float TELEPORT_PAUSE = 0.1f; // fix false postives when teleporting
const float TELEPORT_RADIUS = 128; // radius around teleport destinations to ignore speedhacks (should be big enough to allow 0.05 seconds of movement after teleporting)
const float IGNORE_ZONE_DIST = 256; // speedhacks ignored within this distance from a trigger teleport zone (0.05s of movement)
const float SERVER_LAG_TME = 0.2f; // time between frames to start ignoring speedhacks (probably server freeze)
const float SERVER_LAG_GRACE_PERIOD = 1.0f; // time after server freeze to ignore speedhacks
const float STRAFE_MOVESPEED_BOOST = 1.56f; // how much faster you move when wall strafing or turning while forward strafing

CCVar@ g_enable;
CCVar@ g_killPenalty;

dictionary g_speedhackPrimaryTime; // weapon primary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackSecondaryTime; // weapon secondary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackMinBullets; // min bullets to analyze for being too fast (too low and laggy players get killed)
dictionary g_weaponIds;

array<SpeedState> g_speedStates(g_Engine.maxClients + 1);

EHandle g_replay_ghost;

int g_mode = MODE_OBSERVE;
bool g_loaded_enable_setting = false;
bool g_debug_mode = false;

float g_last_server_lag = 0;

bool g_falldamage_enabled = false;

array<Vector> g_testDirs = {
	Vector(16, 0, 0),
	Vector(-16, 0, 0),
	Vector(0, 16, 0),
	Vector(0, -16, 0),
	Vector(0, 0, 16),
	Vector(0, 0, -16)
};

// order should match weapon ids
array<string> g_weapon_sounds = {
	"weapons/pl_gun3.wav",
	"weapons/desert_eagle_fire.wav",
	"weapons/uzi/shoot1.wav",
	"weapons/357_shot1.wav",
	"weapons/hks1.wav",
	"weapons/sbarrel1.wav",
	"weapons/xbow_fire1.wav",
	"weapons/rocketfire1.wav",
	"weapons/gauss2.wav",
	"agrunt/ag_fire1.wav",
	"weapons/grenade_hit1.wav",
	"weapons/g_bounce1.wav",
	"weapons/sniper_fire.wav",
	"weapons/saw_fire1.wav",
	"weapons/splauncher_fire.wav",
	"hassault/hw_shoot2.wav",
	"weapons/shock_fire.wav",
	"weapons/medshot4.wav",
	"weapons/displacer_fire.wav",
	"weapons/mine_deploy.wav",
	"squeek/sqk_hunt2.wav",
	"weapons/hks1.wav"
};

array<string> early_out_reasons = {
	"SPEEDHACK",
	"AFK/Frozen/Dead",
	"Object/Noclip/Teleport/Barnacle",
	"Object",
	"Teleport",
	"Stuck",
	"Buffer",
	"Not moving",
	"Normal",
	"Lag",
	"Server lag",
	"Throttled net",
	"Map ignore",
	"Steep slope fall"
};

array<IgnoreZone> g_ignore_zones;

CClientCommand _anticheat("anticheat", "AntiCheat", @anticheatToggle, ConCommandFlag::AdminOnly );
CClientCommand _replay("rpcheat", "AntiCheat", @replayCheater, ConCommandFlag::AdminOnly );

CConCommand@ cmdAnticheat;
CConCommand@ cmdCheaterFound;

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook( Hooks::Player::PlayerPostThink, @PlayerPostThink );
	
	g_Scheduler.SetInterval("detect_speedhack", 0.05f, -1);
	g_Scheduler.SetInterval("detect_jumpbug", 0.0f, -1);
	
	@g_enable = CCVar("enable", 0, "Toggle anticheat", ConCommandFlag::AdminOnly);
	@g_killPenalty = CCVar("kill_penalty", 6, "respawn delay for killed speedhackers", ConCommandFlag::AdminOnly);
	
	@cmdAnticheat = @CConCommand( "mode", "Set anticheat mode", @anticheatToggle );
	@cmdCheaterFound = @CConCommand( "cheaterFound", "Cross-plugin command", @cheaterFound );
	
	init();
}

void PluginExit() {
	g_EntityFuncs.Remove(g_replay_ghost);
}

void MapStart() {
	init();
	
	if (!g_loaded_enable_setting) {
		g_mode = g_enable.GetInt();
		g_loaded_enable_setting = true;
	}
}

void init() {
	if (g_debug_mode)
		g_CustomEntityFuncs.RegisterCustomEntity( "monster_ghost", "monster_ghost" );
	
	CBasePlayerWeapon@ mp5 = cast<CBasePlayerWeapon@>(g_EntityFuncs.CreateEntity("weapon_9mmAR", null, true));
	bool isClassicMap = mp5.iMaxClip() == 50;
	g_EntityFuncs.Remove(mp5);

	g_speedhackPrimaryTime["weapon_9mmhandgun"] = 0.21; // longer for primary
	g_speedhackPrimaryTime["weapon_eagle"] = 0.305;
	g_speedhackPrimaryTime["weapon_uzi"] = 0.076;
	g_speedhackPrimaryTime["weapon_357"] = 0.75;
	g_speedhackPrimaryTime["weapon_9mmAR"] = 0.09; // sometimes it double fires
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
	g_speedhackPrimaryTime["weapon_displacer"] = 2.0;
	g_speedhackPrimaryTime["weapon_tripmine"] = 0.305;
	g_speedhackPrimaryTime["weapon_snark"] = 0.305;
	g_speedhackPrimaryTime["weapon_m16"] = 0.14; // actually .168 but too sensitive to lag
	
	// melee weapons can't be speedhacked
	
	g_speedhackSecondaryTime["weapon_9mmAR"] = 1.0; // false positive when doing m2 after m1
	g_speedhackSecondaryTime["weapon_m16"] = 2.3;
	
	if (!isClassicMap) {
		g_speedhackPrimaryTime["weapon_9mmhandgun"] = 0.175;
		g_speedhackPrimaryTime["weapon_shotgun"] = 0.255;
		g_speedhackPrimaryTime["weapon_9mmAR"] = 0.09;
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
	g_weaponIds["weapon_displacer"] = 19;
	g_weaponIds["weapon_tripmine"] = 20;
	g_weaponIds["weapon_snark"] = 21;
	g_weaponIds["weapon_m16"] = 22;
	
	g_speedStates.resize(0);
	g_speedStates.resize(g_Engine.maxClients + 1);
	
	find_relative_teleports();
	
	g_falldamage_enabled = g_EngineFuncs.CVarGetFloat("mp_falldamage") != -1;
	
	g_last_server_lag = -999;
}

string vectorIntString(Vector v) {
	return "" + int32(v.x) + "," + int32(v.y) + "," + int32(v.z);
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
		return "" + time + "_" + vectorIntString(origin) + "_" + vectorIntString(velocity) + "_" + vectorIntString(angles) + "_" 
				  + buttons + "_" + health + "_" + weaponId + "_" + weaponClip + "_" + weaponAmmo + "_" + weaponAmmo2 + "_" + moveDetections;
	}
}

class MoveDetectFrame {
	float time;
	Vector origin;
	Vector velocity;
	Vector angles;
	float actualSpeed;
	float expectedSpeed;
	float avgActual;
	float avgExpected;
	int moveDetections; // number of movement hack detections
	int sussyness;
	int earlyOutReason;
	float timeSincePacket;
	int throttles;
	
	MoveDetectFrame() {}
	
	MoveDetectFrame(CBasePlayer@ plr, SpeedState@ state) {
		this.time = g_Engine.time;
		this.origin = plr.pev.origin;
		this.velocity = plr.pev.velocity;
		this.angles = plr.pev.v_angle;
		this.moveDetections = state.detections;
		this.timeSincePacket = g_Engine.time - state.lastPacket;
		this.throttles = state.throttles;
		
		this.actualSpeed = -1;
		this.expectedSpeed = -1;
		this.avgActual = -1;
		this.avgExpected = -1;
		this.sussyness = 0;
		this.earlyOutReason = 0;
	}
	
	// load from file
	MoveDetectFrame(CBasePlayer@ plr, string line) {
		array<string> parts = line.Split("_");
		if (parts.size() != 13) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "[AntiCheat] Incompatible replay file.\n");
			return;
		}
		
		time = atof(parts[0]);
		g_Utility.StringToVector(origin, parts[1], ",");
		g_Utility.StringToVector(velocity, parts[2], ",");
		g_Utility.StringToVector(angles, parts[3], ",");
		actualSpeed = atoi(parts[4]);
		expectedSpeed = atoi(parts[5]);
		avgActual = atoi(parts[6]);
		avgExpected = atoi(parts[7]);
		moveDetections = atoi(parts[8]);
		sussyness = atoi(parts[9]);
		earlyOutReason = atoi(parts[10]);
		timeSincePacket = atoi(parts[11]);
		throttles = atoi(parts[12]);
	}
	
	string toString() {
		return "" + time + "_" + vectorIntString(origin) + "_" + vectorIntString(velocity) + "_" + vectorIntString(angles) + "_" 
				  + actualSpeed + "_" + expectedSpeed + "_" + avgActual + "_" + avgExpected + "_" + moveDetections + "_" + sussyness
				  + "_" + earlyOutReason + "_" + timeSincePacket + "_" + throttles;
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
	int throttles; // number of times player was going slightly too slow (possible throttled connection)
	float lastDetectTime;
	Vector lastOrigin;
	Vector lastVelocity;
	float lastHealth;
	int lastWepId = -1;
	float lastButtonPress = 0; // last time any buttons were pressed/held
	float lastMovingObjectContact = 0;
	float lastTeleport = 0; // ignore speedhacks shortle after teleporting
	float lastWaterLevel = 0;
	float lastPrimaryCooldown = 0;
	float lastSecondaryCooldown = 0;
	float lastAttack = 0;
	float lastWeaponAnim = 0;
	bool doubleFired = false;

	array<float> lastSpeeds;
	array<float> lastExpectedSpeeds;
	array<float> lastPrimaryShootTimes;
	array<float> lastSecondaryShootTimes;
	array<PlayerFrame> replayHistory;
	array<MoveDetectFrame> detectHistory;
	
	float lastPrimaryClip;
	float lastPrimaryAmmo;
	float lastSecondaryAmmo;
	float lastPacket;
	float waitHackCheck; // wait before checking speedhack because player was lagged for a moment
	bool wasWaiting = false;
	
	SpeedState() {}
	
	void addDebugInfoFrame(MoveDetectFrame@ frame) {
		detectHistory.insertLast(frame);
		if (detectHistory.size() >= MOVE_DETECT_HISTORY_SIZE) {
			detectHistory.removeAt(0);
		}
	}
}

uint32 getPlayerBit(CBaseEntity@ plr) {
	return (1 << (plr.entindex() & 31));
}

void detect_speedhack() {
	if (g_mode == MODE_DISABLE) {
		return;
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		
		MoveDetectFrame dinfo(plr, state);
		
		float timeSinceLastPacket = g_Engine.time - state.lastPacket;
		float timeSinceLastCheck = g_Engine.time - state.lastDetectTime;
		float timeSinceLastButton = g_Engine.time - state.lastButtonPress;
		float timeSinceLastTeleport = g_Engine.time - state.lastTeleport;
		bool isNoclipping = plr.pev.movetype == MOVETYPE_NOCLIP;
		bool isAfk = timeSinceLastButton > AFK_TIME;
		bool isFrozen = plr.pev.flags & FL_FROZEN != 0;
		bool isBarnacled = plr.m_afPhysicsFlags & PFLAG_ONBARNACLE != 0;
		bool serverWasLagged = g_Engine.time - g_last_server_lag < SERVER_LAG_GRACE_PERIOD;
		bool ignoreMapSpeedhack = map_specific_ignore_case(plr);
		state.lastDetectTime = g_Engine.time;
		
		bool isLaggedOut = timeSinceLastPacket > LAGOUT_TIME or state.waitHackCheck > g_Engine.time;
		
		if (isAfk or isFrozen or !plr.IsAlive() or ignoreMapSpeedhack) {
			state.lastOrigin = plr.pev.origin;
			state.detections = Math.max(0, state.detections-1);
			
			dinfo.earlyOutReason = 1;
			state.addDebugInfoFrame(dinfo);
			
			if (ignoreMapSpeedhack) {
				dinfo.earlyOutReason = 12;
			}
			
			//println("PAUSE (lag)");
			continue;
		}
		
		int sussyMovement = detect_movement_speedhack(state, plr, dinfo, timeSinceLastCheck);
		
		float timeSinceLastMovingObjectTouch = g_Engine.time - state.lastMovingObjectContact;
		bool nearMovingObject = timeSinceLastMovingObjectTouch < MOVING_OBJECT_PAUSE_TIME;
		bool wasTeleported = timeSinceLastTeleport < TELEPORT_PAUSE;
		
		if (nearMovingObject or isLaggedOut or isNoclipping or isBarnacled or wasTeleported or serverWasLagged) {
			//println("PAUSE (Object/teleport)");
			state.lastSpeeds.resize(0);
			state.lastExpectedSpeeds.resize(0);
			state.detections = 0;
			
			if (dinfo.earlyOutReason == 0) {
				dinfo.earlyOutReason = 2;
				
				if (serverWasLagged) {
					dinfo.earlyOutReason = 10;
				}
				else if (isLaggedOut) {
					dinfo.earlyOutReason = 9;
				}
			}
				
			state.addDebugInfoFrame(dinfo);
			
			continue;
		}
		
		state.addDebugInfoFrame(dinfo);
		
		if (sussyMovement > 0) {
			state.detections += sussyMovement;
		}
		else if (state.detections > 0) {
			state.detections -= 1;
		}
		
		//if (state.detections > 0)
		//println("SPEEDHACK: " + state.detections + " (+" + sussyMovement + ") " + timeSinceLastPacket);
		
		if (state.detections > HACK_DETECTION_MAX && plr.IsAlive()) {
			kill_hacker(state, plr, "movement speedhack", "move");
		}
	}
}

// no way to tell if a player entered a teleport that preserves angles,
// so this will create boxes around them where speedhacks should be ignored
void find_relative_teleports() {
	g_ignore_zones.resize(0);
	
	Vector buffer(IGNORE_ZONE_DIST, IGNORE_ZONE_DIST, IGNORE_ZONE_DIST);
	
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "trigger_teleport"); 
		if (ent !is null and ent.pev.spawnflags & (128 | 256) != 0) // relative or keep-angles flags
		{
			IgnoreZone zone = IgnoreZone(ent.pev.absmin - buffer, ent.pev.absmax + buffer);
			//println("FOUND RELATIVE TELEPORT " + ent.pev.target + " " + (zone.maxs - zone.mins).ToString());
			g_ignore_zones.insertLast(zone);
		}
	} while (ent !is null);
}

bool is_near_teleport_trigger(CBasePlayer@ plr) {
	Vector pos = plr.pev.origin;
	
	for (uint i = 0; i < g_ignore_zones.size(); i++) {	
		Vector min = g_ignore_zones[i].mins;
		Vector max = g_ignore_zones[i].maxs;
		if (pos.x > min.x and pos.y > min.y and pos.z > min.z and pos.x < max.x and pos.y < max.y and pos.z < max.z) {
			return true;
		}
	}
	
	return false;
}

bool map_specific_ignore_case(CBasePlayer@ plr) {
	// ignore speedhacks on the board because it has tons of undetectable teleports
	if (g_Engine.mapname == "botparty" and plr.pev.origin.z < -2600 and plr.pev.origin.z > -3200) {
		return true;
	}
	
	return false;
}

void kill_hacker(SpeedState@ state, CBasePlayer@ plr, string reason, string shortReason) {
	if (g_mode == MODE_ENABLE) {
		plr.Killed(g_EntityFuncs.Instance( 0 ).pev, GIB_ALWAYS);
		float defaultRespawnDelay = g_EngineFuncs.CVarGetFloat("mp_respawndelay");
		plr.m_flRespawnDelayTime = Math.max(g_killPenalty.GetInt(), defaultRespawnDelay) - defaultRespawnDelay;
		
		string msg = "[AntiCheat] " + plr.pev.netname + " was killed for " + reason + ".\n";
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, msg);
		g_Log.PrintF(msg);
	} else {
		string msg = "[AntiCheat] " + plr.pev.netname + " " + reason + ".\n";
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTCONSOLE, msg);
		g_Log.PrintF(msg);
	}
	
	writeReplayData(state, plr, shortReason);
	
	state.detections = 0;
	state.lastSpeeds.resize(0);
	state.lastExpectedSpeeds.resize(0);
	state.lastPrimaryShootTimes.resize(0);
	state.lastSecondaryShootTimes.resize(0);
	state.replayHistory.resize(0);
}

void detect_jumpbug() {
	if (g_mode == MODE_DISABLE) {
		return;
	}
	
	if (g_Engine.frametime > SERVER_LAG_TME) {
		g_last_server_lag = g_Engine.time;
	}
	
	bool serverIsLagged = g_Engine.time - g_last_server_lag < SERVER_LAG_GRACE_PERIOD;
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		
		if (!plr.IsAlive()) {
			state.lastVelocity = Vector(0,0,0);
			state.lastHealth = 0;
			continue;
		}
		
		bool jumpedInstantlyAfterLanding = state.lastVelocity.z < -JUMPBUG_SPEED and plr.pev.velocity.z > 128;
		bool perfectlyTimedJump = (plr.m_afButtonPressed | plr.m_afButtonReleased) & (IN_JUMP | IN_DUCK) != 0;
		bool preventedDamage = plr.pev.health == state.lastHealth and plr.pev.waterlevel == 0;
		
		if (jumpedInstantlyAfterLanding and perfectlyTimedJump and preventedDamage and !serverIsLagged and g_falldamage_enabled)  {
			TraceResult tr;
			HULL_NUMBER hullType = plr.pev.flags & FL_DUCKING != 0 ? head_hull : human_hull;
			g_Utility.TraceHull( plr.pev.origin, plr.pev.origin + Vector(0, 0, -8), dont_ignore_monsters, hullType, plr.edict(), tr );
			
			// you take no fall damage when landing into an updward slope at high speed. Instead you slide up it.
			bool launchingOffRamp = tr.vecPlaneNormal.z != 1 and tr.flFraction < 0.01f;
			
			// touching or slightly above ground?
			if (tr.flFraction < 1.0f and !launchingOffRamp) {
				kill_hacker(state, plr, "using the jumpbug cheat", "jumpbug");
			}			
		}
		
		state.lastVelocity = plr.pev.velocity;
		state.lastHealth = plr.pev.health;
		
		if (plr.pev.fixangle != 0) {
			// must have been teleported
			state.lastTeleport = g_Engine.time;
		}
		
		// antiblock plugin teleported this player slightly?
		{
			CustomKeyvalues@ tCustom = plr.GetCustomKeyvalues();
			CustomKeyvalue tValue( tCustom.GetKeyvalue( "$f_lastAntiBlock" ) );
			float time = tValue.GetFloat();
			if (time >= g_Engine.time) {
				state.lastTeleport = g_Engine.time;
			}
		}
		
		// portal spawner plugin teleported this player?
		{
			CustomKeyvalues@ tCustom = plr.GetCustomKeyvalues();
			CustomKeyvalue tValue( tCustom.GetKeyvalue( "$f_lastPsTele" ) );
			float time = tValue.GetFloat();
			if (time >= g_Engine.time) {
				state.lastTeleport = g_Engine.time;
			}
		}
	}
	
}

float getMaxSpeed(CBasePlayer@ plr) {
	float maxSpeed = plr.pev.maxspeed;
	
	if (plr.pev.flags & FL_DUCKING != 0) {
		maxSpeed /= 3.0f;
	}
	
	return maxSpeed * STRAFE_MOVESPEED_BOOST;
}

// returns how extreme the speed difference in (1 = minor, 2+ major)
int detect_movement_speedhack(SpeedState@ state, CBasePlayer@ plr, MoveDetectFrame@ dinfo, float timeSinceLastCheck) {
	Vector originDiff = plr.pev.origin - state.lastOrigin;
	Vector expectedVelocity = plr.pev.velocity + plr.pev.basevelocity;
	
	HULL_NUMBER hullType = plr.pev.flags & FL_DUCKING != 0 ? head_hull : human_hull;
	Vector groundNormal = Vector(0,0,1);
	bool onGround = false;

	// velocity/collision gets weird on and around moving objects, ignore those cases
	Vector start = plr.pev.origin;
	for (uint i = 0; i < g_testDirs.size(); i++) {
		TraceResult tr;		
		g_Utility.TraceHull( start, start + g_testDirs[i], dont_ignore_monsters, hullType, plr.edict(), tr );
		CBaseEntity@ pHit = g_EntityFuncs.Instance( tr.pHit );
		
		if (pHit is null) {
			continue;
		}
		
		if (i == 5) {
			groundNormal = tr.vecPlaneNormal;
			onGround = true;
		}
		
		bool isMoving = pHit.pev.velocity.Length() > 1 or pHit.pev.avelocity.Length() > 1;
		
		if (isMoving or pHit.IsMonster() or pHit.pev.classname == "func_conveyor") {
			//println("IGNORE " + pHit.pev.classname);
			state.lastMovingObjectContact = g_Engine.time;
			dinfo.earlyOutReason = 3;
			return 0;
		}
	}
	
	if (is_near_teleport_trigger(plr)) {
		state.lastTeleport = g_Engine.time;
		state.lastOrigin = plr.pev.origin;
		dinfo.earlyOutReason = 4;
		return 0;
	}
	
	// going up/down slopes makes velocity appear faster than it is
	if (onGround) {
		originDiff.z = 0;
		expectedVelocity.z = 0;
	}
	
	float expectedSpeed = (expectedVelocity).Length();
	float actualSpeed = originDiff.Length() * (1.0f / timeSinceLastCheck);
	state.lastOrigin = plr.pev.origin;
	
	dinfo.actualSpeed = actualSpeed;
	dinfo.expectedSpeed = expectedSpeed;
	
	/*
	Vector normalExpected = expectedVelocity.Normalize();
	Vector normalActual = originDiff.Normalize();
	
	if (DotProduct(expectedVelocity, originDiff) < -0.1) {
		// going opposite direction of velocity happens when sliding down slope sometimes
		return 0;
	}
	*/
	
	// fix false positives slowing down your decent on a steep slope while also touching a wall
	// speedhacking here would be pointless and make it harder to survive
	if (actualSpeed > expectedSpeed*MOVEMENT_HACK_RATIO_FAST and groundNormal.z < 0.7 and plr.pev.velocity.z < 0) {
		dinfo.earlyOutReason = 13;
		state.detections = 0;
		return 0;
	}

	if (actualSpeed < expectedSpeed*MOVEMENT_HACK_RATIO_SLOW) {
		// got stuck between two surfaces and is building velocity while not moving.
		
		TraceResult tr;
		g_Utility.TraceHull( plr.pev.origin, plr.pev.origin + plr.pev.velocity.Normalize()*8, dont_ignore_monsters, hullType, plr.edict(), tr );
		if (tr.flFraction < 1.0f or tr.fStartSolid == 1) {
			println("PROBABLY STUCK");
			state.lastSpeeds.resize(0);
			state.lastExpectedSpeeds.resize(0);
			dinfo.earlyOutReason = 5;
			return 0;
		}
	}
	
	state.lastSpeeds.insertLast(actualSpeed);
	state.lastExpectedSpeeds.insertLast(expectedSpeed);
	
	if (state.lastSpeeds.size() > MOVEMENT_HISTORY_SIZE) {
		state.lastSpeeds.removeAt(0);
		state.lastExpectedSpeeds.removeAt(0);
	} else if (state.lastSpeeds.size() < MOVEMENT_HISTORY_SIZE) {
		dinfo.earlyOutReason = 6;
		return 0; // wait for buffer to fill
	}
	
	float avgActual = 0;
	float avgExpected = 0;
	for (uint i = 0; i < state.lastSpeeds.size(); i++) {	
		avgActual += state.lastSpeeds[i];
		avgExpected += state.lastExpectedSpeeds[i];
	}
	avgActual /= float(state.lastSpeeds.size());
	avgExpected /= float(state.lastSpeeds.size());
	
	dinfo.avgActual = avgActual;
	dinfo.avgExpected = avgExpected;	
	
	if (avgExpected == 0) {
		dinfo.earlyOutReason = 7;
		return 0;
	}
	
	// max speed when running normally or wall strafing
	// speedhacks slower than this are ignored because there's nothing gained by cheating that slowly
	// and because weird false positives come up when someone spams the USE key which rapidly changes velocity
	float maxMoveSpeed = getMaxSpeed(plr);
	
	float errorRatio = avgActual / avgExpected;
	bool movingTooFast = avgActual > maxMoveSpeed && avgActual > avgExpected*MOVEMENT_HACK_RATIO_FAST;
	bool movingTooSlow = avgExpected > maxMoveSpeed && avgActual < avgExpected*MOVEMENT_HACK_RATIO_SLOW;
	bool isSpeedWrong = movingTooFast || movingTooSlow;
	
	// if player is moving slightly too slow, their connection might be throttled.
	// Forgive the next speedhack if it's only fast enough to undo the previous slowness
	// and it if happens soon after the throttled packets.
	if (avgActual < avgExpected*0.9) {
		state.throttles += 1;		
		if (state.throttles > 20) { // max 1 second of throttle forgiveness
			state.throttles = 20;
		}
	else if (movingTooFast and state.throttles > 0) {
		state.throttles -= 1;
		dinfo.earlyOutReason = 11;
		return 0;
	}
	} else if (state.throttles > 0) {
		state.throttles -= 1;
	}
	dinfo.throttles = state.throttles;
	
	if (movingTooFast) {
		println("TOO FAST " + (avgActual / avgExpected));
	} else if (movingTooSlow) {
		println("TOO SLOW " + (avgActual / avgExpected));
	}
	
	//println("ERROR RATIO: " + errorRatio);
	
	if (!isSpeedWrong) {
		dinfo.earlyOutReason = 8;
		return 0;
	}
	
	int sussyness = 1;
	
	if (errorRatio > 2) {
		sussyness = 2;
	} else if (errorRatio > 4) {
		sussyness = 4;
	}
	
	dinfo.sussyness = sussyness;
	
	return sussyness;
}

float lastAttack = 0;

int getPrimaryAmmo(CBasePlayer@ plr, CBasePlayerWeapon@ wep) {
	return wep.m_iPrimaryAmmoType > -1 ? plr.m_rgAmmo(wep.m_iPrimaryAmmoType) : 0;
}

int getSecondaryAmmo(CBasePlayer@ plr, CBasePlayerWeapon@ wep) {
	return wep.m_iSecondaryAmmoType > -1 ? plr.m_rgAmmo(wep.m_iSecondaryAmmoType) : 0;
}

HookReturnCode PlayerPostThink(CBasePlayer@ plr) {
	if (g_mode == MODE_DISABLE) {
		return HOOK_CONTINUE;
	}

	SpeedState@ state = g_speedStates[plr.entindex()];	
	
	// Detect if weapons are being shot too quickly
	CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(plr.m_hActiveItem.GetEntity());
	
	state.replayHistory.insertLast(PlayerFrame(plr, wep, state));
	if (state.replayHistory.size() > REPLAY_HISTORY_SIZE) {
		state.replayHistory.removeAt(0);
	}
	
	float timeSinceLastPacket = g_Engine.time - state.lastPacket;
	
	if (timeSinceLastPacket > LAGOUT_TIME) {
		// got disconnected for a moment
		float grace_period = Math.min(LAGOUT_GRACE_PERIOD_MAX, timeSinceLastPacket);
		println("DISCONNECTED FOR A MMOMENT " + grace_period);
		state.waitHackCheck = g_Engine.time + grace_period; // a huge batch of packets is probably coming. Ignore it.
	}
	
	state.lastPacket = g_Engine.time;	
	
	if (state.waitHackCheck > g_Engine.time) {
		state.wasWaiting = true;
		return HOOK_CONTINUE;
	}
	
	if (state.wasWaiting) {
		println("Resume hax check");
		state.wasWaiting = false;
		
		// prevent false positives during lag spikes
		state.lastPrimaryShootTimes.resize(0);
		state.lastSecondaryShootTimes.resize(0);
		state.detections = 0;
		state.lastOrigin = plr.pev.origin;
		state.lastSpeeds.resize(0);
		state.lastExpectedSpeeds.resize(0);
		
		if (wep !is null) {
			state.lastPrimaryClip = wep.m_iClip;
			state.lastPrimaryAmmo = getPrimaryAmmo(plr, wep);
			state.lastSecondaryAmmo = getSecondaryAmmo(plr, wep);
			state.lastPrimaryCooldown = wep.m_flNextPrimaryAttack;
			state.lastSecondaryCooldown = wep.m_flNextSecondaryAttack;
			state.lastAttack = plr.m_flNextAttack;
			state.lastWeaponAnim = plr.pev.weaponanim;
		}
	}
	
	if (plr.m_afButtonPressed | plr.m_afButtonLast | plr.m_afButtonReleased != 0) {
		state.lastButtonPress = g_Engine.time;
	}
	
	if (wep !is null) {
		// primary fired
		bool lessPrimaryAmmo = state.lastPrimaryAmmo > 0 && state.lastPrimaryAmmo > getPrimaryAmmo(plr, wep);
		bool lessSecondaryAmmo = state.lastSecondaryAmmo > 0 && state.lastSecondaryAmmo > getSecondaryAmmo(plr, wep);
		bool primaryCooldownChanged = wep.m_flNextPrimaryAttack > state.lastPrimaryCooldown
									  or plr.m_flNextAttack > state.lastAttack // for gauss
									  or plr.pev.weaponanim != state.lastWeaponAnim; // for displacer
		bool secondaryCooldownChanged = wep.m_flNextSecondaryAttack > state.lastSecondaryCooldown;
		bool lessPrimaryClip = state.lastPrimaryClip > wep.m_iClip;
		bool wasReload = wep.m_iClip > state.lastPrimaryClip;
		
		state.lastPrimaryClip = wep.m_iClip;
		state.lastPrimaryAmmo = getPrimaryAmmo(plr, wep);
		state.lastSecondaryAmmo = getSecondaryAmmo(plr, wep);
		state.lastPrimaryCooldown = wep.m_flNextPrimaryAttack;
		state.lastSecondaryCooldown = wep.m_flNextSecondaryAttack;
		state.lastAttack = plr.m_flNextAttack;
		state.lastWeaponAnim = plr.pev.weaponanim;
		
		if (wep.entindex() != state.lastWepId) {
			state.lastWepId = wep.entindex();
			state.lastPrimaryShootTimes.resize(0);
			state.lastSecondaryShootTimes.resize(0);
			return HOOK_CONTINUE;
		}
		
		float cooldown = 0;
		array<float>@ bulletTimes = null;
		
		// primary fired?
		if ((lessPrimaryAmmo || lessPrimaryClip) && !wasReload && g_speedhackPrimaryTime.exists(wep.pev.classname) and (primaryCooldownChanged || lessPrimaryClip)) {
			g_speedhackPrimaryTime.get(wep.pev.classname, cooldown);
			@bulletTimes = state.lastPrimaryShootTimes;
			
			// weapon loses ammo every frame when secondary used in water
			if (wep.pev.classname == "weapon_shockrifle" and plr.pev.waterlevel != 0) {
				@bulletTimes = null;
			}
		}
		
		// secondary fired?
		if (lessSecondaryAmmo && g_speedhackSecondaryTime.exists(wep.pev.classname) && secondaryCooldownChanged) {
			g_speedhackSecondaryTime.get(wep.pev.classname, cooldown);
			@bulletTimes = state.lastSecondaryShootTimes;
		}
		
		if (bulletTimes !is null) {
			if (bulletTimes.size() >= 2) {
				float lastBulletTime = bulletTimes[bulletTimes.size()-1];
				float lastLastBulletTime = bulletTimes[bulletTimes.size()-2];
				
				float timeSinceLast = g_Engine.time - lastBulletTime;
				float timeBetweenLastAndPrev = lastBulletTime - lastLastBulletTime;
				
				bool reallyFastFire = timeSinceLast < cooldown*0.2f;
				bool previousWasNotTooFast = timeBetweenLastAndPrev >= cooldown * (1.0f/MAX_WEAPON_SPEEDUP);
				
				
				if (reallyFastFire and previousWasNotTooFast and !state.doubleFired) {
					// don't add this bullet to the history, probably was a double-fire bug
					state.doubleFired = true;
					println("DOUBLE FIRED");
					return HOOK_CONTINUE; 
				}
				
				state.doubleFired = false;
			}
			
		
			bulletTimes.insertLast(g_Engine.time);
			if (bulletTimes.size() > BULLET_HISTORY_SIZE) {
				bulletTimes.removeAt(0);
			}
			
			uint bulletsToAnalyze = int(Math.max(3, (WEAPON_ANALYZE_TIME / cooldown) + 0.5f));
			
			if (bulletTimes.size() >= bulletsToAnalyze) {
				float expectedDelta = (bulletsToAnalyze-1)*cooldown;
				float firstBulletTime = bulletTimes[bulletTimes.size() - bulletsToAnalyze];
				float actualDelta = g_Engine.time - firstBulletTime;
				float speedError = actualDelta != 0 ? (expectedDelta / actualDelta) : 99999;
				
				string debugMsg = "" + wep.pev.classname + " Bullets: " + bulletsToAnalyze + ", First: " + firstBulletTime + ", Last: " + g_Engine.time + ", Error: " + actualDelta + " / " + expectedDelta + " = " + speedError;
				println(debugMsg);
			
				if (speedError > MAX_WEAPON_SPEEDUP) {
					string wep_name = wep.pev.classname;
					wep_name.Replace("weapon_", "");
					
					g_Log.PrintF("[AntiCheat] Speedhack on " + plr.pev.netname + " " + debugMsg + "\n");
					kill_hacker(state, plr, wep_name + " speedhack", wep_name);
				}
			}			
		}
	}
	
	
	return HOOK_CONTINUE;
}

void anticheatToggle( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	
	bool newModeSet = false;
	if (args.ArgC() > 1) {
		g_mode = Math.max(0, Math.min(MODE_OBSERVE, atoi(args[1])));
		newModeSet = true;
	}
	
	string newMode = "Enabled.";
	if (g_mode == MODE_DISABLE) {
		newMode = "Disabled.";
	} else if (g_mode == MODE_OBSERVE) {
		newMode = "Observing.";
	}
	
	g_PlayerFuncs.SayText(plr, "[AntiCheat] " + newMode + "\n");
	g_EngineFuncs.ServerPrint("[AntiCheat] " + newMode + "\n");
	
	if (newModeSet) {
		string user = plr !is null ? "-" + string(plr.pev.netname) : "";
		g_Log.PrintF("[AntiCheat] " + newMode + "\n");
	}
}

void cheaterFound(const CCommand@ args) {
	CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(atoi(args[1]));
	
	if (plr is null or !plr.IsConnected()) {
		return;
	}
	
	RelaySay("" + plr.pev.netname + " was kicked for using cheat mods.\n");
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[AntiCheat] " + plr.pev.netname + " was kicked for using cheat mods.\n");
	g_EngineFuncs.ServerCommand("kick #" + g_EngineFuncs.GetPlayerUserId(plr.edict()) + " Disable your cheat mod.\n");
}

void writeReplayData(SpeedState@ state, CBasePlayer@ plr, string reason) {

	DateTime now = DateTime();
	string timeStr = "" + now.GetYear() + "-" + formatInt(now.GetMonth()+1, "0", 2) + "-" + formatInt(now.GetDayOfMonth()+1, "0", 2) + "_" + 
					 formatInt(now.GetHour()+1, "0", 2) + "-" + formatInt(now.GetMinutes()+1, "0", 2) + "-" + formatInt(now.GetSeconds()+1, "0", 2);
	string path = REPLAY_ROOT_PATH + timeStr + "_" + reason + "_" + g_Engine.mapname + "_" + plr.pev.netname + ".txt";
	
	File@ f = g_FileSystem.OpenFile(path, OpenFile::WRITE);
	
	if (f is null or !f.IsOpen()) {
		g_Log.PrintF("[AntiCheat] Failed to open replay file for writing: " + path + "\n");
		return;
	}
	
	for (uint i = 0; i < state.replayHistory.size(); i++) {
		f.Write(state.replayHistory[i].toString() + "\n");
	}
	
	f.Write("BEGIN_MOVE_DETECT_REPLAY\n");
	
	for (uint i = 0; i < state.detectHistory.size(); i++) {
		f.Write(state.detectHistory[i].toString() + "\n");
	}
	
	f.Write("BEGIN_BULLET_DATA\n");
	
	for (uint i = 0; i < state.lastPrimaryShootTimes.size(); i++) {
		f.Write("" + state.lastPrimaryShootTimes[i]);
		if (int(i) < int(state.lastPrimaryShootTimes.size())-1) {
			f.Write(",");
		}
	}
	f.Write("\n");
	for (uint i = 0; i < state.lastSecondaryShootTimes.size(); i++) {
		f.Write("" + state.lastSecondaryShootTimes[i] + ",");
		if (int(i) < int(state.lastSecondaryShootTimes.size()-1)) {
			f.Write(",");
		}
	}
	f.Write("\n");
	
	f.Write("STEAM_ID: " + g_EngineFuncs.GetPlayerAuthId( plr.edict() ) + "\n");
	
	f.Close();
	
	float duration = g_Engine.time - state.replayHistory[0].time;
	
	println("[AntiCheat] Wrote " + duration + "s replay file: " + path + "\n");
}

void debug_replay(EHandle h_watcher, EHandle h_ghost, array<PlayerFrame>@ frames, float startTime, int startFrame, float speed, int lastFrame) {
	CBaseEntity@ ghost = h_ghost;
	
	if (ghost is null) {
		return;
	}
	
	float t = (g_Engine.time - startTime)*speed;
	if (t + frames[startFrame].time > frames[frames.size()-1].time + 1.0f*speed) { 
		startTime = g_Engine.time;
		println("Replay finished");
	}
	
	for (int i = int(frames.size())-1; i >= startFrame; i--) {
		if (t + frames[startFrame].time >= frames[i].time) {
			if (i != lastFrame) {
				for (int k = lastFrame+1; k <= i; k++) {
					PlayerFrame@ frame = frames[k];
					
					ghost.pev.origin = frame.origin;
					ghost.pev.angles = frame.angles;
					ghost.pev.angles.x = -ghost.pev.angles.x;
			
					if (lastFrame >= 0 and lastFrame < i) {
						bool shotWeapon = frames[k-1].weaponAmmo > frames[k].weaponAmmo
											|| frames[k-1].weaponClip > frames[k].weaponClip;
						if (shotWeapon) {
							uint8 sndId = frame.weaponId-1;
							if (sndId >= 0 and sndId < g_weapon_sounds.size()) {
								g_SoundSystem.PlaySound(ghost.edict(), CHAN_AUTO, g_weapon_sounds[sndId], 1.0f, 0.0f, 0, 100);
							}
						}
					}
					
					int nextFrameTime = k < int(frames.size())-1 ? int((frames[k+1].time - frame.time)*1000) : -1;
					println("Time: " + formatFloat(frame.time, "", 6, 3)
							+ ", Frame " + formatInt(k, "", 3)
							+ ", Speed: " + formatInt(int(frame.velocity.Length()), "", 4)
							+ ", Buttons: " + formatInt(frame.buttons, "", 5)
							+ ", Weapon: " + formatInt(frame.weaponId, "", 2)
							+ ", Ammo: " + formatInt(frame.weaponClip, "", 3) + " " + formatInt(frame.weaponAmmo, "", 3)
							+ ", HP: " + formatInt(int(frame.health), "", 3)
							+ ", detections: " + formatInt(frame.moveDetections, "", 2)
							+ ", nextFrame: " + formatInt(nextFrameTime, "", 3) + "ms");
					
					CBaseEntity@ watcher = h_watcher;
				}
			}
			
			lastFrame = i;
			
			break;
		}
	}
	
	g_Scheduler.SetTimeout("debug_replay", 0.0f, h_watcher, h_ghost, @frames, startTime, startFrame, speed, lastFrame);
}

void debug_detect_replay(EHandle h_watcher, EHandle h_ghost, array<MoveDetectFrame>@ frames, float startTime, int startFrame, float speed, int lastFrame) {
	CBaseEntity@ ghost = h_ghost;
	
	if (ghost is null) {
		return;
	}
	
	float t = (g_Engine.time - startTime)*speed;
	if (t + frames[startFrame].time > frames[frames.size()-1].time + 1.0f*speed) { 
		startTime = g_Engine.time;
		println("Replay finished");
	}
	
	for (int i = int(frames.size())-1; i >= startFrame; i--) {
		if (t + frames[startFrame].time >= frames[i].time) {
			if (i != lastFrame) {
				for (int k = lastFrame+1; k <= i; k++) {
					MoveDetectFrame@ frame = frames[k];
					
					ghost.pev.origin = frame.origin;
					ghost.pev.angles = frame.angles;
					ghost.pev.angles.x = -ghost.pev.angles.x;
					
					float error = 0;
					if (frame.expectedSpeed != 0) {
						error = frame.actualSpeed / frame.expectedSpeed;
					}
					
					float avgError = 0;
					if (frame.avgExpected != 0) {
						avgError = frame.avgActual / frame.avgExpected;
					}
					
					string earlyOut = frame.earlyOutReason >= 0 and frame.earlyOutReason < int(early_out_reasons.size()) ? early_out_reasons[frame.earlyOutReason] : ("" + frame.earlyOutReason);
					
					if (frame.sussyness > 0) {
						earlyOut += " (+" + frame.sussyness + ")";
					}
					
					int nextFrameTime = k < int(frames.size())-1 ? int((frames[k+1].time - frame.time)*1000) : -1;
					println("Frame " + formatInt(k, "", 3)
							+ ", Speed: " + formatInt(int(frame.actualSpeed), "", 4) + " / " + formatInt(int(frame.expectedSpeed), "", 4) + " = " + formatFloat(error, "", 6, 2)
							+ ", Avg: " + formatInt(int(frame.avgActual), "", 4) + " / " + formatInt(int(frame.avgExpected), "", 4) + " = " + formatFloat(avgError, "", 6, 2)
							+ ", detect: " + formatInt(frame.moveDetections, "", 2) 
							+ ", throttle: " + formatInt(frame.throttles, "", 2) 
							+ ", nextFrame: " + formatInt(nextFrameTime, "", 3) + "ms"
							+ ", Status: " + earlyOut);
							
					
					CBaseEntity@ watcher = h_watcher;
				}
			}
			
			lastFrame = i;
			
			break;
		}
	}
	
	g_Scheduler.SetTimeout("debug_detect_replay", 0.0f, h_watcher, h_ghost, @frames, startTime, startFrame, speed, lastFrame);
}

void replayCheater( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	
	string path = REPLAY_ROOT_PATH + args[1];
	bool replayDetects = atoi(args[2]) != 0;
	int frameOffset = atoi(args[3]);
	float speed = atof(args[4]);
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
	
	int parseMode = 0;
	array<PlayerFrame> frames;
	array<MoveDetectFrame> detectFrames;
	array<float> primaryBulletTimes;
	array<float> secondaryBulletTimes;
	
	while (!file.EOFReached()) {
		string line;
		file.ReadLine(line);
		
		if (line.IsEmpty()) {
			continue;
		}
		
		if (line == "BEGIN_MOVE_DETECT_REPLAY") {
			parseMode = 1;
			continue;
		}
		if (line == "BEGIN_BULLET_DATA") {			
			file.ReadLine(line);
			
			array<string> parts = line.Split(",");
			for (uint i = 0; i < parts.size(); i++) {
				primaryBulletTimes.insertLast(atof(parts[i]));
			}
			
			file.ReadLine(line);
			
			parts = line.Split(",");
			for (uint i = 0; i < parts.size(); i++) {
				secondaryBulletTimes.insertLast(atof(parts[i]));
			}
			
			break;
		}
		if (line.Find("STEAM") == 0) {
			break;
		}
		
		if (parseMode == 1) {
			detectFrames.insertLast(MoveDetectFrame(plr, line));
		} else {
			frames.insertLast(PlayerFrame(plr, line));
		}
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
	
	ent.pev.controller[0] = 127;
	ent.pev.controller[1] = 127;
	ent.pev.controller[2] = 127;
	ent.pev.controller[3] = 127;
	
	g_EntityFuncs.Remove(g_replay_ghost);
	g_replay_ghost = ent;
	
	plr.pev.origin = frames[frames.size()-1].origin;
	//plr.pev.origin = frames[0].origin;
	
	println("Start " + frames.size() + " replay from " + frames[0].time);
	
	if (replayDetects)
		g_Scheduler.SetTimeout("debug_detect_replay", 0.5f, EHandle(plr), g_replay_ghost, detectFrames, g_Engine.time, frameOffset, speed, -1);
	else
		g_Scheduler.SetTimeout("debug_replay", 0.5f, EHandle(plr), g_replay_ghost, frames, g_Engine.time, frameOffset, speed, -1);
}