void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

array<float> lastCrowbarPlayer;

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "github" );
	
	g_Hooks.RegisterHook( Hooks::Player::PlayerTakeDamage, @PlayerTakeDamage );
	
	lastCrowbarPlayer.resize(0);
	lastCrowbarPlayer.resize(33);
}

void MapInit() {
	lastCrowbarPlayer.resize(0);
	lastCrowbarPlayer.resize(33);
}

HookReturnCode PlayerTakeDamage(DamageInfo@ info) {
	CBaseEntity@ inflictor = @info.pInflictor;
	
	if (inflictor is null || !inflictor.IsPlayer() || info.bitsDamageType != DMG_CLUB) {
		return HOOK_CONTINUE;
	}
	
	CBasePlayerWeapon@ wep = cast<CBasePlayerWeapon@>(cast<CBasePlayer@>(inflictor).m_hActiveItem.GetEntity());
	if (wep is null || string(wep.pev.classname) != "weapon_crowbar") {
		return HOOK_CONTINUE;
	}
	
	int eidx = inflictor.entindex();
	if (g_EngineFuncs.Time() - lastCrowbarPlayer[eidx] < 0.02f) {
		// TODO: maybe wait for 2-3 fast hits so lag spikes trigger this less often
		g_EntityFuncs.Remove(wep);
		
		g_EntityFuncs.CreateEntity("weapon_crowbar", {
			{"origin", inflictor.pev.origin.ToString()},
			{"angles", inflictor.pev.angles.ToString()},
			{"spawnflags", "1024"}
		}, true);
	}
	lastCrowbarPlayer[eidx] = g_EngineFuncs.Time();	
	
	return HOOK_CONTINUE;
}