#pragma once
#include "meta_utils.h"

typedef struct usercmd_s
{
	short	lerp_msec;      // Interpolation time on client
	byte	msec;           // Duration in ms of command
	vec3_t	viewangles;     // Command view angles.

// intended velocities
	float	forwardmove;    // Forward velocity.
	float	sidemove;       // Sideways velocity.
	float	upmove;         // Upward velocity.
	byte	lightlevel;     // Light level at spot where we are standing.
	unsigned short  buttons;  // Attack buttons
	byte    impulse;          // Impulse command issued.
	byte	weaponselect;	// Current weapon id

// Experimental player impact stuff.
	int		impact_index;
	vec3_t	impact_position;
} usercmd_t;

#define	MAX_PHYSENTS 600
#define MAX_MOVEENTS 64
#define MAX_PHYSINFO_STRING 256

typedef struct physent_s
{
	char			name[32];             // Name of model, or "player" or "world".
	int				player;
	vec3_t			origin;               // Model's origin in world coordinates.
	struct model_s* model;		          // only for bsp models
	struct model_s* studiomodel;         // SOLID_BBOX, but studio clip intersections.
	vec3_t			mins, maxs;	          // only for non-bsp models
	int				info;		          // For client or server to use to identify (index into edicts or cl_entities)
	vec3_t			angles;               // rotated entities need this info for hull testing to work.

	int				solid;				  // Triggers and func_door type WATER brushes are SOLID_NOT
	int				skin;                 // BSP Contents for such things like fun_door water brushes.
	int				rendermode;			  // So we can ignore glass

	// Complex collision detection.
	float			frame;
	int				sequence;
	byte			controller[4];
	byte			blending[2];

	int				movetype;
	int				takedamage;
	int				blooddecal;
	int				team;
	int				classnumber;

	// For mods
	int				iuser1;
	int				iuser2;
	int				iuser3;
	int				iuser4;
	float			fuser1;
	float			fuser2;
	float			fuser3;
	float			fuser4;
	vec3_t			vuser1;
	vec3_t			vuser2;
	vec3_t			vuser3;
	vec3_t			vuser4;
} physent_t;

typedef struct
{
	vec3_t	normal;
	float	dist;
} pmplane_t;

typedef struct pmtrace_s
{
	qboolean	allsolid;	      // if true, plane is not valid
	qboolean	startsolid;	      // if true, the initial point was in a solid area
	qboolean	inopen, inwater;  // End point is in empty space or in water
	float		fraction;		  // time completed, 1.0 = didn't hit anything
	vec3_t		endpos;			  // final position
	pmplane_t	plane;		      // surface normal at impact
	int			ent;			  // entity at impact
	vec3_t      deltavelocity;    // Change in player's velocity caused by impact.  
								  // Only run on server.
	int         hitgroup;
} pmtrace_t;

struct playermove_s
{
	int				player_index;  // So we don't try to run the PM_CheckStuck nudging too quickly.
	qboolean		server;        // For debugging, are we running physics code on server side?

	qboolean		multiplayer;   // 1 == multiplayer server
	float			time;          // realtime on host, for reckoning duck timing
	float			frametime;	   // Duration of this frame

	vec3_t			forward, right, up; // Vectors for angles
	// player state
	vec3_t			origin;        // Movement origin.
	vec3_t			angles;        // Movement view angles.
	vec3_t			oldangles;     // Angles before movement view angles were looked at.
	vec3_t			velocity;      // Current movement direction.
	vec3_t			movedir;       // For waterjumping, a forced forward velocity so we can fly over lip of ledge.
	vec3_t			basevelocity;  // Velocity of the conveyor we are standing, e.g.

	// For ducking/dead
	vec3_t			view_ofs;      // Our eye position.
	float			flDuckTime;    // Time we started duck
	qboolean		bInDuck;       // In process of ducking or ducked already?

	// For walking/falling
	int				flTimeStepSound;  // Next time we can play a step sound
	int				iStepLeft;

	float			flFallVelocity;
	vec3_t			punchangle;

	float			flSwimTime;

	float			flNextPrimaryAttack;

	int				effects;		// MUZZLE FLASH, e.g.

	int				flags;         // FL_ONGROUND, FL_DUCKING, etc.
	int				usehull;       // 0 = regular player hull, 1 = ducked player hull, 2 = point hull
	float			gravity;       // Our current gravity and friction.
	float			friction;
	int				oldbuttons;    // Buttons last usercmd
	float			waterjumptime; // Amount of time left in jumping out of water cycle.
	qboolean		dead;          // Are we a dead player?
	int				deadflag;
	int				spectator;     // Should we use spectator physics model?
	int				movetype;      // Our movement type, NOCLIP, WALK, FLY

	int				onground;
	int				waterlevel;
	int				watertype;
	int				oldwaterlevel;

	char			sztexturename[256];
	char			chtexturetype;

	float			maxspeed;
	float			clientmaxspeed; // Player specific maxspeed

	// For mods
	int				iuser1;
	int				iuser2;
	int				iuser3;
	int				iuser4;
	float			fuser1;
	float			fuser2;
	float			fuser3;
	float			fuser4;
	vec3_t			vuser1;
	vec3_t			vuser2;
	vec3_t			vuser3;
	vec3_t			vuser4;
	// world state
	// Number of entities to clip against.
	int				numphysent;
	physent_t		physents[MAX_PHYSENTS];
	// Number of momvement entities (ladders)
	int				nummoveent;
	// just a list of ladders
	physent_t		moveents[MAX_MOVEENTS];

	// All things being rendered, for tracing against things you don't actually collide with
	int				numvisent;
	physent_t		visents[MAX_PHYSENTS];

	// input to run through physics.
	usercmd_t		cmd;

	// Trace results for objects we collided with.
	int				numtouch;
	pmtrace_t		touchindex[MAX_PHYSENTS];

	char			physinfo[MAX_PHYSINFO_STRING]; // Physics info string

	struct movevars_s* movevars;
	vec3_t player_mins[4];
	vec3_t player_maxs[4];
};

void MapInit(edict_t* pEdictList, int edictCount, int clientMax);
void MapInit_post(edict_t* pEdictList, int edictCount, int clientMax);
void StartFrame();
void ClientJoin(edict_t* pEntity);
void PlayerPreThink(edict_t* pEntity);
void PlayerPostThink(edict_t* pEntity);
void PlayerPostThink_post(edict_t* pEntity);
void PM_Move(struct playermove_s* ppmove, int server);
void PM_Move_post(struct playermove_s* ppmove, int server);
void ClientLeave(edict_t* pEntity);
void StartFrame();
void CvarValue2(const edict_t* pEnt, int requestID, const char* cvarName, const char* value);
void ClientCommand(edict_t* pEntity);
void loadSpeedhackWhitelist();
void loadLogFilter();
