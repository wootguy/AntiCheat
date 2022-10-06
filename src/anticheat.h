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

void MapInit(edict_t* pEdictList, int edictCount, int clientMax);
void StartFrame();
void ClientJoin(edict_t* pEntity);
void ClientLeave(edict_t* pEntity);
void CmdStart(const edict_t* player, const struct usercmd_s* cmd, unsigned int random_seed);
void StartFrame();
void CvarValue2(const edict_t* pEnt, int requestID, const char* cvarName, const char* value);
