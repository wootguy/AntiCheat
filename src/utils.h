#pragma once
#include "anticheat.h"

string replaceString(string subject, string search, string replace);

edict_t* getPlayerByUniqueId(string id);

// user IDs change every time a user connects to the server
edict_t* getPlayerByUserId(int id);

const char* getPlayerUniqueId(edict_t* plr);

edict_t* getPlayerByName(edict_t* caller, string name);

bool isPlayerAlive(edict_t* plr);

bool isValidPlayer(edict_t* plr);

void clientCommand(edict_t* plr, string cmd, int destType = MSG_ONE);

string trimSpaces(string s);

bool cgetline(FILE* file, string& output);

string formatTime(int totalSeconds);

vector<string> splitString(string str, const char* delimitters);

uint32_t getFileSize(FILE* file);

float clampf(float val, float min, float max);

int clamp(int val, int min, int max);