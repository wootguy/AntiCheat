// False positives:
// - poke646_elevator running into buttons
// - stuck inside wedge?

// TODO:
// - pausing near pushing entities is overkill yet still triggers false positives
// - less tolerant for 1.4x weapon speedup over long durations, maybe go down to 1.1x

const float MOVEMENT_HACK_RATIO_FAST = 1.1f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_RATIO_SLOW = 0.5f; // how much actual and expected movement speed can differ
const float MOVEMENT_HACK_MIN = 96; // min movement speed before detecting speedhack (detection inaccurate at low values)
const int HACK_DETECTION_MAX = 20; // max number of detections before killing player (expect some false positives)
const int MAX_CMDS_PER_SECOND = 220; // max number of commands/sec before it's speedhacking (200 max FPS + some buffer)
const float WEAPON_COOLDOWN_EPSILON = 0.05f; // allow this much error in cooldown time
const float JUMPBUG_SPEED = 580; // fall speed to detect jump bug (min amount for damage)
const float MAX_WEAPON_SPEEDUP = 1.4f; // max allowed speedhack on weapons (too low might kill innocent players)
const float WEAPON_ANALYZE_TIME = 1.5f; // minimum continous shooting time to detect hacking
const float MIN_BULLET_DELAY = 0.05f; // little faster than the fastest shooting weapon
const int BULLET_HISTORY_SIZE = (WEAPON_ANALYZE_TIME / MIN_BULLET_DELAY);
const int MOVEMENT_HISTORY_SIZE = 8; // bigger = better lag tolerance, but short speedhacks are undetected
const float LAGOUT_TIME = 0.1f; // pause speedhack checks if there's a gap in player commands longer than this
const float LAGOUT_GRACE_PERIOD = 0.1f; // time to pause speedhack checks after lag spike.
const int REPLAY_HISTORY_SIZE = 1024; // number of packets to remember per player, for debugging speedhack detections
const string REPLAY_ROOT_PATH = "scripts/plugins/store/anticheat_replay/";
const float AFK_TIME = 5.0f; // min time to not be pressing buttons before speedhack checks are disabled
const float MOVING_OBJECT_PAUSE_TIME = 0.5f; // fix false postives when rubbing past or jumping off a moving platform
const float TELEPORT_PAUSE = 0.1f; // fix false postives when teleporting
const float TELEPORT_RADIUS = 128; // radius around teleport destinations to ignore speedhacks (should be big enough to allow 0.05 seconds of movement after teleporting)

CCVar@ g_enable;
CCVar@ g_killPenalty;

dictionary g_speedhackPrimaryTime; // weapon primary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackSecondaryTime; // weapon secondary fires that are affected by speedhacking. Value is expected delay.
dictionary g_speedhackMinBullets; // min bullets to analyze for being too fast (too low and laggy players get killed)
dictionary g_weaponIds;

array<SpeedState> g_speedStates(g_Engine.maxClients + 1);

EHandle g_replay_ghost;

enum MODE {
	MODE_DISABLE, // disable all checks (for testing server lag)
	MODE_ENABLE,  // kill speedhackers
	MODE_OBSERVE  // detect cheats and write replay data but don't kill anyone
}

int g_mode = MODE_OBSERVE;
bool g_loaded_enable_setting = false;
bool g_debug_mode = false;

array<Vector> g_testDirs = {
	Vector(8, 0, 0),
	Vector(-8, 0, 0),
	Vector(0, 8, 0),
	Vector(0, -8, 0),
	Vector(0, 0, 8),
	Vector(0, 0, -8)
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
}

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
	"weapons/m16_3round.wav"
};

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
	float lastButtonPress = 0; // last time any buttons were pressed/held
	float lastMovingObjectContact = 0;
	float lastTeleport = 0; // ignore speedhacks shortle after teleporting
	float lastWaterLevel = 0;

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
	if (g_mode == MODE_DISABLE) {
		return;
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected() or !plr.IsAlive()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		
		float timeSinceLastPacket = g_Engine.time - state.lastPacket;
		float timeSinceLastCheck = g_Engine.time - state.lastDetectTime;
		float timeSinceLastButton = g_Engine.time - state.lastButtonPress;
		float timeSinceLastTeleport = g_Engine.time - state.lastTeleport;
		bool isNoclipping = plr.pev.movetype == MOVETYPE_NOCLIP;
		state.lastDetectTime = g_Engine.time;
		
		if (timeSinceLastButton > AFK_TIME) {
			// prevent AFK ropes triggering speedhacks
			//println("AFK IGNORE");
			continue;
		}
		
		if (plr.pev.flags & FL_FROZEN != 0) {
			continue; // players keep velocity on cutscenes that freeze players
		}
		
		if (timeSinceLastPacket > LAGOUT_TIME) {
			// got disconnected for a moment
			println("DISCONNECTED FOR A MMOMENT " + timeSinceLastCheck);
			state.waitHackCheck = g_Engine.time + LAGOUT_GRACE_PERIOD; // a huge batch of packets is probably coming. Ignore it.
		}
		
		if (timeSinceLastPacket > LAGOUT_TIME or state.waitHackCheck > g_Engine.time) {
			state.lastOrigin = plr.pev.origin;
			//println("PAUSE (lag)");
			continue;
		}
		
		int sussyMovement = detect_movement_speedhack(state, plr, timeSinceLastCheck);
		
		float timeSinceLastMovingObjectTouch = g_Engine.time - state.lastMovingObjectContact;
		if (timeSinceLastMovingObjectTouch < MOVING_OBJECT_PAUSE_TIME or isNoclipping or timeSinceLastTeleport < TELEPORT_PAUSE) {
			//println("PAUSE (Object/teleport)");
			state.lastOrigin = plr.pev.origin;
			state.lastSpeeds.resize(0);
			state.lastExpectedSpeeds.resize(0);
			state.detections = 0;
			continue;
		}
		
		if (sussyMovement > 0) {
			state.detections += sussyMovement;
		}
		else if (state.detections > 0) {
			state.detections -= 1;
		}
		
		//println("SPEEDHACK: " + state.detections + " (+" + sussyMovement + ") " + timeSinceLastPacket);
		
		if (state.detections > HACK_DETECTION_MAX && plr.IsAlive()) {
			kill_hacker(state, plr, "speedhacking");
		}
	}
}

bool is_near_teleport_destination(CBasePlayer@ plr) {
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityInSphere(ent, plr.pev.origin, TELEPORT_RADIUS, "info_teleport_destination", "classname"); 
		if (ent !is null)
		{
			return true;
		}
	} while (ent !is null);
	
	return false;
}

void kill_hacker(SpeedState@ state, CBasePlayer@ plr, string reason) {
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
	
	println("[AntiCheat] Wrote " + duration + "s replay file: " + path + "\n");
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
							if (sndId > 0 and sndId < g_weapon_sounds.size()) {
								g_SoundSystem.PlaySound(ghost.edict(), CHAN_AUTO, g_weapon_sounds[sndId], 1.0f, 0.0f, 0, 100);
							}
						}
					}
					
					int nextFrameTime = k < int(frames.size())-1 ? int((frames[k+1].time - frame.time)*1000) : -1;
					println("Time: " + formatFloat(frame.time, "", 6, 3)
							+ ", Frame " + formatInt(k, "", 3)
							//+ ", FrameTime " + formatFloat(frame.time, "", 6, 3)
							+ ", Speed: " + formatInt(int(frame.velocity.Length()), "", 4)
							+ ", Buttons: " + formatInt(frame.buttons, "", 5)
							+ ", Weapon: " + formatInt(frame.weaponId, "", 2)
							+ ", Ammo: " + formatInt(frame.weaponClip, "", 3) + " " + formatInt(frame.weaponAmmo, "", 3)
							+ ", HP: " + formatInt(int(frame.health), "", 3)
							+ ", detections: " + formatInt(frame.moveDetections, "", 2)
							+ ", nextFrame: " + formatInt(nextFrameTime, "", 3) + "ms");
				}
			}
			
			lastFrame = i;
			
			break;
		}
	}
	
	g_Scheduler.SetTimeout("debug_replay", 0.0f, h_ghost, @frames, startTime, startFrame, speed, lastFrame);
}

void detect_jumpbug() {
	if (g_mode == MODE_DISABLE) {
		return;
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected() or !plr.IsAlive()) {
			continue;
		}
		
		SpeedState@ state = g_speedStates[plr.entindex()];
		bool jumpedInstantlyAfterLanding = state.lastVelocity.z < -JUMPBUG_SPEED and plr.pev.velocity.z > 128;
		bool perfectlyTimedJump = (plr.m_afButtonPressed | plr.m_afButtonReleased) & (IN_JUMP | IN_DUCK) != 0;
		bool preventedDamage = plr.pev.health == state.lastHealth and plr.pev.waterlevel == 0;
		
		if (jumpedInstantlyAfterLanding and perfectlyTimedJump and preventedDamage)  {
			kill_hacker(state, plr, "using the jumpbug cheat");
		}
		
		state.lastVelocity = plr.pev.velocity;
		state.lastHealth = plr.pev.health;
		
		if (plr.pev.fixangle != 0) {
			// must have been teleported
			state.lastTeleport = g_Engine.time;
		}
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
			state.lastOrigin = plr.pev.origin;
			state.lastMovingObjectContact = g_Engine.time;
			return 0; // too complicated to calculate where the player is expected to be
		}
		
		expectedVelocity = expectedVelocity + pTrain.pev.velocity;
	}
	
	{
		// TODO: calculate inbetween conveyors (hl_c09 smasher section)
		TraceResult tr;		
		g_Utility.TraceHull( plr.pev.origin, plr.pev.origin + Vector(0,0,-32), ignore_monsters, human_hull, plr.edict(), tr );
		CBaseEntity@ pStand = g_EntityFuncs.Instance( tr.pHit );
		
		if (pStand !is null and pStand.pev.classname == "func_conveyor") {
			state.lastOrigin = plr.pev.origin;
			state.lastMovingObjectContact = g_Engine.time;
			return 0; // ignore speedhack on conveyor
		}
	}
	
	// being pushed by entities doesn't update velocity, so allow faster movement around moving ents
	Vector start = plr.pev.origin;
	for (uint i = 0; i < g_testDirs.size(); i++) {
		TraceResult tr;		
		g_Utility.TraceHull( start, start + g_testDirs[i], ignore_monsters, human_hull, plr.edict(), tr );
		CBaseEntity@ pHit = g_EntityFuncs.Instance( tr.pHit );
		
		if (pHit !is null and (pHit.pev.velocity.Length() > 1 or pHit.pev.avelocity.Length() > 1)) {
			println("IGNORE " + pHit.pev.classname);
			state.lastMovingObjectContact = g_Engine.time;
			return 0;
		}
	}
	
	if (is_near_teleport_destination(plr)) {
		state.lastTeleport = g_Engine.time;
		state.lastOrigin = plr.pev.origin;
		return 0;
	}
	
	// going up/down slopes makes velocity appear faster than it is
	originDiff.z = 0;
	expectedVelocity.z = 0;
	
	float expectedSpeed = (expectedVelocity).Length();
	float actualSpeed = originDiff.Length() * (1.0f / timeSinceLastCheck);
	state.lastOrigin = plr.pev.origin;
	
	if (actualSpeed < expectedSpeed*MOVEMENT_HACK_RATIO_SLOW) {
		// got stuck between two surfaces and is building velocity while not moving.
		TraceResult tr;		
		g_Utility.TraceHull( plr.pev.origin, plr.pev.origin + plr.pev.velocity.Normalize(), dont_ignore_monsters, human_hull, plr.edict(), tr );
		if (tr.flFraction < 1.0f) {
			println("PROBABLY STUCK");
			state.lastSpeeds.resize(0);
			state.lastExpectedSpeeds.resize(0);
			return 0;
		}
	}
	
	state.lastSpeeds.insertLast(actualSpeed);
	state.lastExpectedSpeeds.insertLast(expectedSpeed);
	
	if (state.lastSpeeds.size() > MOVEMENT_HISTORY_SIZE) {
		state.lastSpeeds.removeAt(0);
		state.lastExpectedSpeeds.removeAt(0);
	} else if (state.lastSpeeds.size() < MOVEMENT_HISTORY_SIZE) {
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
	
	if (avgExpected == 0) {
		return 0;
	}
	
	float errorRatio = avgActual / avgExpected;
	bool movingTooFast = avgActual > MOVEMENT_HACK_MIN && avgActual > avgExpected*MOVEMENT_HACK_RATIO_FAST;
	bool movingTooSlow = avgExpected > MOVEMENT_HACK_MIN && avgActual < avgExpected*MOVEMENT_HACK_RATIO_SLOW;
	bool isSpeedWrong = movingTooFast || movingTooSlow;
	
	if (movingTooFast) {
		println("TOO FAST " + (avgActual / avgExpected));
	} else if (movingTooSlow) {
		println("TOO SLOW " + (avgActual / avgExpected));
	}
	
	//println("ERROR RATIO: " + errorRatio);
	
	if (!isSpeedWrong) {
		return 0;
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
	
	float timeSinceLastCheck = g_Engine.time - state.lastPacket;
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
	}
	
	if (plr.m_afButtonPressed | plr.m_afButtonLast != 0) {
		state.lastButtonPress = g_Engine.time;
	}
	
	if (wep !is null) {
		// primary fired
		bool lessPrimaryAmmo = state.lastPrimaryAmmo > 0 && state.lastPrimaryAmmo > getPrimaryAmmo(plr, wep);
		bool lessSecondaryAmmo = state.lastSecondaryAmmo > 0 && state.lastSecondaryAmmo > getSecondaryAmmo(plr, wep);
		bool lessPrimaryClip = state.lastPrimaryClip > wep.m_iClip;
		bool wasReload = wep.m_iClip > state.lastPrimaryClip;
		
		state.lastPrimaryClip = wep.m_iClip;
		state.lastPrimaryAmmo = getPrimaryAmmo(plr, wep);
		state.lastSecondaryAmmo = getSecondaryAmmo(plr, wep);
		
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
CClientCommand _replay("rpcheat", "AntiCheat", @replayCheater );

void anticheatToggle( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	g_mode = Math.max(0, Math.min(MODE_OBSERVE, atoi(args[1])));
	
	string newMode = "Enabled.";
	if (g_mode == MODE_DISABLE) {
		newMode = "Disabled.";
	} else if (g_mode == MODE_OBSERVE) {
		newMode = "Observing.";
	}
	
	g_PlayerFuncs.SayText(plr, "[AntiCheat] " + newMode + "\n");
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
	//plr.pev.origin = frames[0].origin;
	
	println("Start " + frames.size() + " replay from " + frames[0].time);
	g_Scheduler.SetTimeout("debug_replay", 0.5f, g_replay_ghost, frames, g_Engine.time, frameOffset, speed, -1);
}