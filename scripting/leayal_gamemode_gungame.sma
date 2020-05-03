#pragma compress 1
#pragma semicolon 1

// ==================================================================
// Special thanks to AlliedModder community (for info). And Bailopan and reCSDM authors for CSDM's spawn locations and code to parse and use them.
// ==================================================================

// Uncomment the line below to enable test features.
// #define TEST

#include <amxmodx>
#include <amxmisc>
#include <hamsandwich>
#include <cstrike_const>
#include <cstrike>
#include <fakemeta>
#include <fakemeta_util>

#include <json>
#include <fun>
#include <cssdk_const>
#include <leayal_task_const>
#include <screenfade_util>

// ReHLDS & ReGameDll_CS
#include <reapi>

#define CVAR_FreeForAll "mp_freeforall"
#define CVAR_Respawn "mp_forcerespawn"
#define CVAR_WeaponStay "mp_item_staytime"
#define CVAR_RoundFreezeTime "mp_freezetime"
#define CVAR_GrenadeRefillTime "leayal_gamemode_gungame_nade_refill_time"
#define CVAR_GivenArmorOnSpawn "leayal_gamemode_gungame_default_armor"

#define Func_BuyZone "func_buyzone"

#define CVAR_HUD_REFRESH "leayal_gamemode_gungame_hud_refresh"
#define CVAR_HUD_R "leayal_gamemode_gungame_hud_r"
#define CVAR_HUD_G "leayal_gamemode_gungame_hud_g"
#define CVAR_HUD_B "leayal_gamemode_gungame_hud_b"

#define FW_OnLevelUp "GunGame_LevelUpPost"
#define FW_OnConfigLoaded "GunGame_ConfigLoaded"
#define FW_OnMatchEnded "GunGame_MatchEnded"

#define MAX_SPAWNS 64
#define Vector(%1,%2,%3) (Float:{%1.0, %2.0, %3.0})
#define VECTOR_ZERO Vector(0, 0, 0)

// Helpers
#define IsVectorZero(%1) (%1[X] == 0.0 && %1[Y] == 0.0 && %1[Z] == 0.0)
#define IsPlayer(%1) (1 <= %1 <= MAX_PLAYERS)

new const WPN_KNIFE[] = "weapon_knife";
const Float:MIN_SPAWN_RADIUS = 200.0;

enum gg_table_weapon_data
{
    tb_wpn_kills,
    tb_wpn_name[65],
    tb_wpn_id[33]
}

enum gg_level_save
{
    save_level,
    save_kills
}

enum gameState
{
    state_begin,
    state_ongoing,
    state_ended,
}

enum hudSyncChannel
{
    Channel_Scoreboard
}

enum dataFreezeCVarValue
{
    frozencvar_pcvar,
    frozencvar_length,
    frozencvar_value[65]
}

enum
{    
    GR_NONE = 0,
    
    GR_WEAPON_RESPAWN_YES,
    GR_WEAPON_RESPAWN_NO,
    
    GR_AMMO_RESPAWN_YES,
    GR_AMMO_RESPAWN_NO,
    
    GR_ITEM_RESPAWN_YES,
    GR_ITEM_RESPAWN_NO,

    GR_PLR_DROP_GUN_ALL,
    GR_PLR_DROP_GUN_ACTIVE,
    GR_PLR_DROP_GUN_NO,

    GR_PLR_DROP_AMMO_ALL,
    GR_PLR_DROP_AMMO_ACTIVE,
    GR_PLR_DROP_AMMO_NO,
}; 

enum coordinate { Float:X, Float:Y, Float:Z }

new hudColors[3];
new Float:hudRefreshRate, Float:cvar_nadeRefill;

new gameState:f_gameState;

new pcvar_ffa = 0,
    pcvar_respawn = 0,
    pcvar_weaponStay = 0;
new cvarhook:hpcvar_weaponStay;

new bool:is_ffa = false;
new bool:has_nativeRespawn = false;

new cvar_respawn = 0,
    cvar_armorOnSpawn,
    Float:cvar_freezetime;

new bool:f_isProtected[MAX_PLAYERS + 1];
new playerLevels[MAX_PLAYERS + 1];
new playerLevelKills[MAX_PLAYERS + 1];
new hudSyncChannels[hudSyncChannel];
new bool:is_givingWpn[MAX_PLAYERS + 1];

new Float:g_vecSpotOrigin[MAX_SPAWNS][coordinate],
	Float:g_vecSpotVAngles[MAX_SPAWNS][coordinate],
	Float:g_vecSpotAngles[MAX_SPAWNS][coordinate];
new g_iLastSpawnIndex[MAX_CLIENTS + 1], bool:g_bFirstSpawn[MAX_CLIENTS + 1]; // g_pAimedEntity[MAX_CLIENTS + 1]
new g_szSpawnDirectory[PLATFORM_MAX_PATH], g_szSpawnFile[PLATFORM_MAX_PATH + 32], g_szMapName[32];
new g_iTotalPoints;

new Trie:playerSavedLevels;
new Array:tb_level;
new Trie:tb_frozenCvar;

new fwh_gg_cfgloaded, fwh_gg_levelup, fwh_gg_matchend;

// Supports plugin_pause
new Array:FWEvents, Array:FWLogEvents, Array:HamHooks, Array:HookChains;
new HookChain:phc_RoundEnd, HookChain:phc_SpawnSpot;

/*
==================================================================================
Plugin Public Fowards
==================================================================================
*/
public plugin_init()
{
    register_plugin("[GameMode] Gungame", "1.0", "Dramiel Leayal");

    tb_level = ArrayCreate(gg_table_weapon_data);
    playerSavedLevels = TrieCreate();
    
    new const pointer_ffa[] = CVAR_FreeForAll;
    pcvar_ffa = get_cvar_pointer(pointer_ffa);
    if (pcvar_ffa == 0)
    {
        pcvar_ffa = create_cvar(pointer_ffa, "0", FCVAR_SERVER | FCVAR_SPONLY, "Determine whether the game mode is free-for-all.", true, 0.0, true, 1.0);
    }
    hook_cvar_change(pcvar_ffa, "OnCvarChanged");

    new const pointer_respawn[] = CVAR_Respawn;
    pcvar_respawn = get_cvar_pointer(pointer_respawn);
    if (pcvar_respawn == 0)
    {
        pcvar_respawn = create_cvar(pointer_respawn, "3", FCVAR_SERVER | FCVAR_SPONLY, "Determine whether the game allowed respawn and how long the respawn will take.", true, 0.0, true, 1.0);
    }
    else
    {
        has_nativeRespawn = true;
    }
    hook_cvar_change(pcvar_respawn, "OnCvarChanged");

    new const pointer_weaponStay[] = CVAR_WeaponStay;
    pcvar_weaponStay = get_cvar_pointer(pointer_weaponStay);
    if (pcvar_weaponStay == 0)
    {
        pcvar_weaponStay = create_cvar(pointer_respawn, "1", FCVAR_SERVER | FCVAR_SPONLY, "Determine whether the game allowed weapon drop on death.", true, 0.0, true, 0.0);
    }
    else
    {
        has_nativeRespawn = true;
    }
    set_pcvar_num(pcvar_weaponStay, 1);
    hpcvar_weaponStay = hook_cvar_change(pcvar_weaponStay, "Cvar_Frozen");

    bind_pcvar_num(create_cvar(CVAR_HUD_R, "200", FCVAR_SERVER | FCVAR_SPONLY, "Gets or sets the Red color channel of scoreboard HUD.", true, 0.0, true, 255.0), hudColors[0]);
    bind_pcvar_num(create_cvar(CVAR_HUD_G, "130", FCVAR_SERVER | FCVAR_SPONLY, "Gets or sets the Green color channel of scoreboard HUD.", true, 0.0, true, 255.0), hudColors[1]);
    bind_pcvar_num(create_cvar(CVAR_HUD_B, "0", FCVAR_SERVER | FCVAR_SPONLY, "Gets or sets the Blue color channel of scoreboard HUD.", true, 0.0, true, 255.0), hudColors[2]);
    bind_pcvar_float(create_cvar(CVAR_HUD_REFRESH, "1.0", FCVAR_SERVER | FCVAR_SPONLY, "Gets or sets the refresh rate of scoreboard HUD.", true, 0.5), hudRefreshRate);
    bind_pcvar_float(create_cvar(CVAR_GrenadeRefillTime, "2.0", FCVAR_SERVER | FCVAR_SPONLY, "Gets or sets time to refill grenade after throwing.", true, 0.5), cvar_nadeRefill);
    bind_pcvar_num(create_cvar(CVAR_GivenArmorOnSpawn, "0", FCVAR_SERVER | FCVAR_SPONLY, "Gets or sets armor value on player spawn.", true, 0.0, true, 200.0), cvar_armorOnSpawn);
    new pcvar_freezetime = get_cvar_pointer(CVAR_RoundFreezeTime);
    if (pcvar_freezetime)
    {
        bind_pcvar_float(pcvar_freezetime, cvar_freezetime);
    }
    else
    {
        cvar_freezetime = 0.0;
    }

    // ========== Forwards, events and hooks ===============
    // FWEvents = ArrayCreate();
    // ArrayPushCell(FWEvents, register_event("HLTV", "OnNewRound", "a", "1=0", "2=0")); // This event will be raised upon new round (When the freeze timer starts to countdown)

    // FWLogEvents = ArrayCreate();
    // ArrayPushCell(FWLogEvents, register_logevent("OnRoundStart", 2, "1=Round_Start")); // will be raised upon match starts (When the freeze timer has ended)

    HookChains = ArrayCreate();
    phc_RoundEnd = RegisterHookChain(RG_RoundEnd, "OnRoundEnd", false);
    phc_SpawnSpot = RegisterHookChain(RG_CSGameRules_GetPlayerSpawnSpot, "OnGetPlayerSpawnSpot", false);
    if (phc_SpawnSpot) DisableHookChain(phc_SpawnSpot);
    ArrayPushCell(HookChains, phc_RoundEnd);
    ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_RestartRound, "OnNewRound", true));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_OnRoundFreezeEnd, "OnRoundStart", true));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_CanHavePlayerItem, "HookChain_PlayerCanPickup", false));
    ArrayPushCell(HookChains, RegisterHookChain(RG_ThrowHeGrenade, "HookChain_PlayerThrowGrenade", true));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_RestartRound, "OnNewRound", false));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CBasePlayer_HasRestrictItem, "HookChain_OnHasRestrictItem", false));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CBasePlayer_OnSpawnEquip, "HookChain_EquippingSpawnPlayer", false));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_FlPlayerFallDamage, "OnPlayerCanTakeDmg", false));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_FPlayerCanTakeDamage, "OnPlayerCanTakeDmg", false));
    ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_DeadPlayerWeapons, "OnDeadPlayerDropItems", false));
    // ArrayPushCell(HookChains, RegisterHookChain(RG_CSGameRules_FShouldSwitchWeapon, "", false));
    // ArrayPushCell(HookChains, RegisterHookChain(RG_CBasePlayer_GiveDefaultItems, "HookChain_PlayerGiveDefaultItems", false));
    // RG_CSGameRules_DeadPlayerWeapons RG_CSGameRules_RestartRound

    // RegisterHam(Ham_Touch, "weapon_hegrenade", "player_touchweapon")
    // RegisterHam(Ham_Touch, "weaponbox", "player_touchweapon")
    // RegisterHam(Ham_Touch, "armoury_entity", "player_touchweapon")
    // RG_CBasePlayer_Spawn
    // RG_CBasePlayer_RoundRespawn

    fwh_gg_levelup = CreateMultiForward(FW_OnLevelUp, ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
    fwh_gg_cfgloaded = CreateMultiForward(FW_OnConfigLoaded, ET_IGNORE);
    fwh_gg_matchend = CreateMultiForward(FW_OnMatchEnded, ET_IGNORE, FP_CELL);

    if (IsHamValid(Ham_CS_Item_CanDrop))
    {
        if (!HamHooks) HamHooks = ArrayCreate();
        static wpn_idName[33];
        for (new csw = CSW_NONE + 1; csw < CSW_LAST_WEAPON; csw++)
        {
            if (get_weaponname(csw, wpn_idName, 32) > 0)
            {
                ArrayPushCell(HamHooks, RegisterHam(Ham_CS_Item_CanDrop, wpn_idName, "Ham_PreventExecute"));
            }
        }
    }
    if (IsHamValid(Ham_Touch))
    {
        if (!HamHooks) HamHooks = ArrayCreate();
        ArrayPushCell(HamHooks, RegisterHam(Ham_Touch, "weaponbox", "Ham_PreventExecute"));
        ArrayPushCell(HamHooks, RegisterHam(Ham_Touch, "armoury_entity", "Ham_PreventExecute"));
    }
    else
    {
        // set_fail_state("Can't register 'Ham_Touch' (%i) of Hamsandwich. Gameplay cannot be init.", Ham_Touch);
    }
    if (IsHamValid(Ham_Killed))
    {
        if (!HamHooks) HamHooks = ArrayCreate();
        ArrayPushCell(HamHooks, RegisterHamPlayer(Ham_Killed, "Ham_PlayerKilled", true));
    }
    else
    {
        set_fail_state("Can't register 'Ham_Killed' (%i) of Hamsandwich. Gameplay cannot be init.", Ham_Killed);
    }
    if (IsHamValid(Ham_Spawn))
    {
        if (!HamHooks) HamHooks = ArrayCreate();
        ArrayPushCell(HamHooks, RegisterHamPlayer(Ham_Spawn, "Ham_PlayerSpawned", true));
    }
    else
    {
        set_fail_state("Can't register 'Ham_Spawn' (%i) of Hamsandwich. Gameplay cannot be init.", Ham_Spawn);
    }
    
    hudSyncChannels[Channel_Scoreboard] = CreateHudSyncObj();

    register_forward(FM_GetGameDescription, "OnGetGameDescription");
    #if defined TEST
    register_clcmd("gg_levelup", "ClCmd_DEBUG_LevelUp");
    // register_clcmd("gg_levelup", "ClCmd_DEBUG_LevelUp");
    #endif
}

public OnGetGameDescription()
{ 
    static game[] = "CS1.6: Gungame";
    // format(game, 31, "CS1.6: Gungame");
    forward_return(FMV_STRING, game);
    return FMRES_SUPERCEDE;
}  

public CSBot_Init(entityId)
{
    if (IsHamValid(Ham_Killed))
    {
        if (!HamHooks) HamHooks = ArrayCreate();
        ArrayPushCell(HamHooks, RegisterHamFromEntity(Ham_Killed, entityId, "Ham_PlayerKilled", true));
    }
    else
    {
        set_fail_state("Can't register 'Ham_Killed' (%i) of Hamsandwich for bots. Gameplay cannot be init.", Ham_Killed);
    }
    if (IsHamValid(Ham_Spawn))
    {
        if (!HamHooks) HamHooks = ArrayCreate();
        ArrayPushCell(HamHooks, RegisterHamFromEntity(Ham_Spawn, entityId, "Ham_PlayerSpawned", true));
    }
    else
    {
        set_fail_state("Can't register 'Ham_Spawn' (%i) of Hamsandwich for bots. Gameplay cannot be init.", Ham_Spawn);
    }
}

public plugin_cfg()
{
    // Read JSON as CFG.
    new path[257];
    get_configsdir(path, 256);
    format(path, 256, "%s%s", path, "/leayal/gamemodes/gungame.json");
    //with this it will try to open file: amxmodx/configs/leayal/gamemodes/gungame.json

    if (!file_exists(path)) return;

    new JSON:json = json_parse(path, true, true);
    if (json != Invalid_JSON)
    {
        new const prop_wpns[] = "weapons";
        if (json_object_has_value(json, prop_wpns))
        {
            new JSON:wpn_data = json_object_get_value(json, prop_wpns);
            if (wpn_data != Invalid_JSON)
            {
                new count = json_object_get_count(wpn_data);
                if (count > 0)
                {
                    new _struct[gg_table_weapon_data];
                    new charOf_tb_wpn_id = charsmax(_struct[tb_wpn_id]);
                    new left[8], right[65 - 8];
                    new rlen = charsmax(right);
                    for (new i = 0; i < count; i++)
                    {
                        if (json_object_get_name(wpn_data, i, _struct[tb_wpn_id], charOf_tb_wpn_id))
                        {
                            if (strtok2(_struct[tb_wpn_id], left, 7, right, rlen, '_') != -1)
                            {
                                if (equali(left, "weapon"))
                                {
                                    if ((_struct[tb_wpn_kills] = json_object_get_number(wpn_data, _struct[tb_wpn_id])) > 0)
                                    {
                                        console_print(0, "[Gungame] Weapon: %s, level: %i, kills: %i", _struct[tb_wpn_id], i + 1, _struct[tb_wpn_kills]);
                                        ArrayPushArray(tb_level, _struct);
                                    }
                                }
                                else
                                {
                                    console_print(0, "[Gungame] Invalid Weapon: %s", _struct[tb_wpn_id], json_object_get_number(wpn_data, _struct[tb_wpn_id]));
                                }
                            }
                            else
                            {
                                console_print(0, "[Gungame] Invalid Weapon: %s", _struct[tb_wpn_id], json_object_get_number(wpn_data, _struct[tb_wpn_id]));
                            }
                        }
                    }
                }
                json_free(wpn_data);
            }
        }

        new const prop_cvars[] = "cvars";
        if (json_object_has_value(json, prop_cvars))
        {
            new JSON:cvars_data = json_object_get_value(json, prop_cvars);
            if (cvars_data != Invalid_JSON)
            {
                new count = json_object_get_count(cvars_data);
                if (count > 0)
                {
                    new JSON:cvars_val = Invalid_JSON;
                    new buffer_cvarName[129], buffer_cvarValue[257];
                    for (new i = 0; i < count; i++)
                    {
                        if (json_object_get_name(cvars_data, i, buffer_cvarName, 128))
                        {
                            cvars_val = json_object_get_value(cvars_data, buffer_cvarName);
                            if (cvars_val != Invalid_JSON)
                            {
                                switch (json_get_type(cvars_val))
                                {
                                    case JSONString:
                                    {
                                        if (json_get_string(cvars_val, buffer_cvarValue, 256))
                                        {
                                            new pcvar = get_cvar_pointer(buffer_cvarName);
                                            if (pcvar)
                                            {
                                                console_print(0, "[Gungame] Setting '%s' to '%s'", buffer_cvarName, buffer_cvarValue);
                                                set_pcvar_string(pcvar, buffer_cvarValue);
                                            }
                                            else
                                            {
                                                console_print(0, "[Gungame] Failed to set '%s'", buffer_cvarName);
                                            }
                                        }
                                    }
                                    case JSONNumber:
                                    {
                                        new pcvar = get_cvar_pointer(buffer_cvarName);
                                        if (pcvar)
                                        {
                                            new Float:duh = json_get_real(cvars_val);
                                            console_print(0, "[Gungame] Setting '%s' to '%f'", buffer_cvarName, duh);
                                            set_pcvar_float(pcvar, duh);
                                        }
                                        else
                                        {
                                            console_print(0, "[Gungame] Failed to set '%s'", buffer_cvarName);
                                        }
                                    }
                                    case JSONBoolean:
                                    {
                                        new pcvar = get_cvar_pointer(buffer_cvarName);
                                        if (pcvar)
                                        {
                                            new bool:duh = json_get_bool(cvars_val);
                                            console_print(0, "[Gungame] Setting '%s' to '%s'", buffer_cvarName, duh ? "true" : "false");
                                            set_pcvar_bool(pcvar, duh);
                                        }
                                        else
                                        {
                                            console_print(0, "[Gungame] Failed to set '%s'", buffer_cvarName);
                                        }
                                    }
                                    case JSONObject:
                                    {
                                        new JSON:cvars_val2 = json_object_get_value(cvars_val, "value");
                                        if (cvars_val2 != Invalid_JSON)
                                        {
                                            new JSONType:type = json_get_type(cvars_val2);
                                            if (type == JSONString && json_get_string(cvars_val2, buffer_cvarValue, 256))
                                            {
                                                new pcvar = get_cvar_pointer(buffer_cvarName);
                                                if (pcvar)
                                                {
                                                    console_print(0, "[Gungame] Setting '%s' to '%s'", buffer_cvarName, buffer_cvarValue);
                                                    set_pcvar_string(pcvar, buffer_cvarValue);
                                                    if (json_object_get_bool(cvars_val, "freeze"))
                                                    {
                                                        if (!tb_frozenCvar) tb_frozenCvar = TrieCreate();
                                                        static arr[dataFreezeCVarValue], skey[4];
                                                        arr[frozencvar_pcvar] = pcvar;
                                                        arr[frozencvar_length] = copy(arr[frozencvar_value], charsmax(arr[frozencvar_value]), buffer_cvarValue);
                                                        if (num_to_str(pcvar, skey, 3) && TrieSetArray(tb_frozenCvar, skey, arr, dataFreezeCVarValue))
                                                        {
                                                            console_print(0, "[Gungame] Freeze cvar '%s' to '%s'", buffer_cvarName, buffer_cvarValue);
                                                            hook_cvar_change(pcvar, "Cvar_Frozen");
                                                        }
                                                    }
                                                }
                                                else
                                                {
                                                    console_print(0, "[Gungame] Failed to set '%s'", buffer_cvarName);
                                                }
                                            }
                                            else if (type == JSONNumber)
                                            {
                                                new pcvar = get_cvar_pointer(buffer_cvarName);
                                                if (pcvar)
                                                {
                                                    new Float:duh = json_get_real(cvars_val2);
                                                    console_print(0, "[Gungame] Setting '%s' to '%f'", buffer_cvarName, duh);
                                                    set_pcvar_float(pcvar, duh);
                                                    if (json_object_get_bool(cvars_val, "freeze"))
                                                    {
                                                        if (!tb_frozenCvar) tb_frozenCvar = TrieCreate();
                                                        static arr[dataFreezeCVarValue], skey[4];
                                                        arr[frozencvar_pcvar] = pcvar;
                                                        arr[frozencvar_length] = format(arr[frozencvar_value], charsmax(arr[frozencvar_value]), "%f", duh);
                                                        if (num_to_str(pcvar, skey, 3) && TrieSetArray(tb_frozenCvar, skey, arr, dataFreezeCVarValue))
                                                        {
                                                            console_print(0, "[Gungame] Freeze cvar '%s' to '%f'", buffer_cvarName, duh);
                                                            hook_cvar_change(pcvar, "Cvar_Frozen");
                                                        }
                                                    }
                                                }
                                                else
                                                {
                                                    console_print(0, "[Gungame] Failed to set '%s'", buffer_cvarName);
                                                }
                                            }
                                            else if (type == JSONBoolean)
                                            {
                                                new pcvar = get_cvar_pointer(buffer_cvarName);
                                                if (pcvar)
                                                {
                                                    new bool:duh = json_get_bool(cvars_val2);
                                                    console_print(0, "[Gungame] Setting '%s' to '%s'", buffer_cvarName, duh ? "true" : "false");
                                                    set_pcvar_bool(pcvar, duh);
                                                    if (json_object_get_bool(cvars_val, "freeze"))
                                                    {
                                                        if (!tb_frozenCvar) tb_frozenCvar = TrieCreate();
                                                        static arr[dataFreezeCVarValue], skey[4];
                                                        arr[frozencvar_pcvar] = pcvar;
                                                        arr[frozencvar_length] = format(arr[frozencvar_value], charsmax(arr[frozencvar_value]), "%i", duh ? "1" : "0");
                                                        if (num_to_str(pcvar, skey, 3) && TrieSetArray(tb_frozenCvar, skey, arr, dataFreezeCVarValue))
                                                        {
                                                            console_print(0, "[Gungame] Freeze cvar '%s' to '%s'", buffer_cvarName, duh ? "true" : "false");
                                                            hook_cvar_change(pcvar, "Cvar_Frozen");
                                                        }
                                                    }
                                                }
                                                else
                                                {
                                                    console_print(0, "[Gungame] Failed to set '%s'", buffer_cvarName);
                                                }
                                            }
                                            json_free(cvars_val2);
                                        }
                                        // GREAT. IT'S ANOTHER OBJECT TO PARSE!!!!
                                    }
                                }
                                json_free(cvars_val);
                            }
                        }
                    }
                }
                json_free(cvars_data);
            }
        }

        new const prop_cmds[] = "commands";
        if (json_object_has_value(json, prop_cmds))
        {
            new JSON:cvars_data = json_object_get_value(json, prop_cmds);
            if (cvars_data != Invalid_JSON)
            {
                new count = json_array_get_count(cvars_data);
                if (count > 0)
                {
                    new buffer_cmds[257];
                    for (new i = 0; i < count; i++)
                    {
                        if (json_array_get_string(cvars_data, i, buffer_cmds, 256))
                        {
                            console_print(0, "[Gungame] Exec command from config: %s", buffer_cmds);
                            server_cmd(buffer_cmds);
                        }
                    }
                }
                json_free(cvars_data);
            }
        }

        json_free(json);
    }

    new iLen = get_configsdir(g_szSpawnDirectory, charsmax(g_szSpawnDirectory));
	formatex(g_szSpawnDirectory[iLen], charsmax(g_szSpawnDirectory) - iLen, "%s/csdm/spawns", g_szSpawnDirectory[iLen]);
    if (dir_exists(g_szSpawnDirectory) == 0)
    {
        mkdir(g_szSpawnDirectory);
    }

	get_mapname(g_szMapName, charsmax(g_szMapName));
	formatex(g_szSpawnFile, charsmax(g_szSpawnFile), "%s/%s.spawns.cfg", g_szSpawnDirectory, g_szMapName);
	LoadPoints();

    if (fwh_gg_cfgloaded)
    {
        ExecuteForward(fwh_gg_cfgloaded);
    }
}

public plugin_pause()
{
    if (hpcvar_weaponStay)
    {
        disable_cvar_hook(hpcvar_weaponStay);
    }
    if (phc_RoundEnd)
    {
        DisableHookChain(phc_RoundEnd);
    }
    if (HamHooks)
    {
        new count = ArraySize(HamHooks);
        new HamHook:hook;
        for (new i = 0; i < count; i++)
        {
            hook = HamHook:ArrayGetCell(HamHooks, i);
            if (hook)
            {
                DisableHamForward(hook);
            }
        }
    }
    if (HookChains)
    {
        new count = ArraySize(HookChains);
        new HookChain:hook;
        for (new i = 0; i < count; i++)
        {
            hook = HookChain:ArrayGetCell(HookChains, i);
            if (hook)
            {
                DisableHookChain(hook);
            }
        }
    }
    if (FWEvents)
    {
        new count = ArraySize(FWEvents);
        new handle;
        for (new i = 0; i < count; i++)
        {
            handle = ArrayGetCell(FWEvents, i);
            if (handle)
            {
                disable_event(handle);
            }
        }
    }
    if (FWLogEvents)
    {
        new count = ArraySize(FWLogEvents);
        new handle;
        for (new i = 0; i < count; i++)
        {
            handle = ArrayGetCell(FWLogEvents, i);
            if (handle)
            {
                disable_logevent(handle);
            }
        }
    }
}

public plugin_unpause()
{
    if (hpcvar_weaponStay)
    {
        set_pcvar_num(pcvar_weaponStay, 1);
        enable_cvar_hook(hpcvar_weaponStay);
    }
    if (HamHooks)
    {
        new count = ArraySize(HamHooks);
        new HamHook:hook;
        for (new i = 0; i < count; i++)
        {
            hook = HamHook:ArrayGetCell(HamHooks, i);
            if (hook)
            {
                EnableHamForward(hook);
            }
        }
    }
    if (HookChains)
    {
        new count = ArraySize(HookChains);
        new HookChain:hook;
        for (new i = 0; i < count; i++)
        {
            hook = HookChain:ArrayGetCell(HookChains, i);
            if (hook)
            {
                EnableHookChain(hook);
            }
        }
    }
    if (FWEvents)
    {
        new count = ArraySize(FWEvents);
        new handle;
        for (new i = 0; i < count; i++)
        {
            handle = ArrayGetCell(FWEvents, i);
            if (handle)
            {
                enable_event(handle);
            }
        }
    }
    if (FWLogEvents)
    {
        new count = ArraySize(FWLogEvents);
        new handle;
        for (new i = 0; i < count; i++)
        {
            handle = ArrayGetCell(FWLogEvents, i);
            if (handle)
            {
                enable_logevent(handle);
            }
        }
    }
}

public plugin_end()
{
    if (fwh_gg_matchend)
    {
        DestroyForward(fwh_gg_matchend);
    }
    if (fwh_gg_cfgloaded)
    {
        DestroyForward(fwh_gg_cfgloaded);
    }
    if (fwh_gg_levelup)
    {
        DestroyForward(fwh_gg_levelup);
    }
    if (tb_level)
    {
        ArrayDestroy(tb_level);
    }
    if (playerSavedLevels)
    {
        TrieDestroy(playerSavedLevels);
    }
    if (HookChains)
    {
        ArrayDestroy(HookChains);
    }
    if (HamHooks)
    {
        ArrayDestroy(HamHooks);
    }
    if (tb_frozenCvar)
    {
        TrieDestroy(tb_frozenCvar);
    }
}

public client_connect(id)
{
    g_bFirstSpawn[id] = true;
}

public client_putinserver(pPlayer)
{
	g_iLastSpawnIndex[pPlayer] = -1;
	g_bFirstSpawn[pPlayer] = false;
}

// Purely for supporting re-connect and resume the game from previous level.
public client_authorized(id, const authId[])
{
    static const str_BOT[] = "BOT";
    if (equali(authId, str_BOT))
    {
        playerLevels[id] = 0;
        playerLevelKills[id] = 0;
    }
    else
    {
        static _struct[gg_level_save];
        static size = sizeof _struct;
        if (playerSavedLevels && TrieGetArray(playerSavedLevels, authId, _struct, size))
        {
            playerLevels[id] = _struct[save_level];
            playerLevelKills[id] = _struct[save_kills];
        }
        else
        {
            playerLevels[id] = 0;
            playerLevelKills[id] = 0;
        }
        
        StartShowScoreBoard(id);
    }
}

public client_disconnected(id, bool:isDropped, message[], maxlen)
{
    f_isProtected[id] = false;
    if (is_user_bot(id) || !is_user_authorized(id)) return;

    StopShowScoreBoard(id);

    static authId[65];
    if (get_user_authid(id, authId, 64))
    {
        static _struct[gg_level_save];
        static size = sizeof _struct; 
        if (playerSavedLevels)
        {
            _struct[save_level] = playerLevels[id];
            _struct[save_kills] = playerLevelKills[id];
            TrieSetArray(playerSavedLevels, authId, _struct, size, true);
        }
    }
}

/*
=============================================================================
Hook Callbacks
=============================================================================
*/
public Ham_PlayerKilled(this, pevAttacker, shouldgib)
{
    // "this": The ID of the person who was killed.
    // "pevAttacker": The entity ID of the person who killed "this".
    // "iGib": Unknown. Could be "is headshot or something"
    // levels[pevAttacker]++;
    // playerLevels[id]
    // playerLevelKills[id]

    // StopShowScoreBoard(this, true);
    remove_task(this + TASK_REFILL_THROWN_GRENADE, false);

    // You're killing yourself.
    if (this == pevAttacker || f_gameState != state_ongoing) return HAM_IGNORED;

    // Teamkilling in teamplay will not be tolerated.
    if (!is_ffa && (get_user_team(this) == get_user_team(pevAttacker)))
    {
        // a
        // client_print_color(this, RED, "^x01You are killed by^x04 %n^x01 (^x04%i^x01 HP)", pevAttacker, get_user_health(pevAttacker));
        return HAM_IGNORED;
    }
    
    // client_print_color(this, RED, "^x01You are killed by^x04 %n^x01 (^x04%i^x01 HP)", pevAttacker, get_user_health(pevAttacker));
    static _struct[gg_table_weapon_data];
    if (TryGetTableLevel(playerLevels[pevAttacker], _struct))
    {
        playerLevelKills[pevAttacker]++;
        if (playerLevelKills[pevAttacker] >= _struct[tb_wpn_kills])
        {
            playerLevelKills[pevAttacker] = 0;
            new level_before = playerLevels[pevAttacker];
            playerLevels[pevAttacker]++;
            UpdateScoreBoardSingle(pevAttacker);
            OnLevelUp(pevAttacker, level_before, playerLevels[pevAttacker]);

            if (f_gameState == state_ongoing && playerLevels[pevAttacker] >= TableLevelCount())
            {
                console_print(0, "%n has won the game. Restarting the game.", pevAttacker);
                OnGameEnded(pevAttacker);
            }
        }
        else
        {
            UpdateScoreBoardSingle(pevAttacker);
        }
    }
    else if (f_gameState == state_ongoing && playerLevels[pevAttacker] >= TableLevelCount())
    {
        console_print(0, "%n has won the game. Restarting the game.", pevAttacker);
        OnGameEnded(pevAttacker);
    }
    return HAM_IGNORED;
}

public Ham_PlayerSpawned(this)
{
    // "this": The ID of the player who get respawned.
    if (!is_user_alive(this)) return;

    if (f_gameState == state_ended)
    {
        RemoveAllWeapons(this, true);
        UTIL_FadeToBlack(0, 0.0);
        // set_pev(this, pev_flags, pev(this, pev_flags) | FL_FROZEN);
        return;
    }
    
    f_isProtected[this] = true;
    set_task(1.0, "Task_StopSpawnProtection", this + TASK_SPAWN_PROTECTION);
    // StartShowScoreBoard(this);
}

public HookChain_OnHasRestrictItem(const this, ItemID:item, ItemRestType:type)
{
    if (f_gameState != state_ongoing) return HC_CONTINUE;
    
    if (type == ITEM_TYPE_TOUCHED)
    {
        SetHookChainReturn(ATYPE_BOOL, true);
        return HC_SUPERCEDE;
    }

    return HC_CONTINUE;
}

public HookChain_EquippingSpawnPlayer(const this, bool:addDefault, bool:equipGame)
{
    if (f_gameState != state_ongoing) return HC_CONTINUE;

    if (cvar_armorOnSpawn > 0)
    {
        rg_set_user_armor(this, cvar_armorOnSpawn, ARMOR_VESTHELM);
    }

    // 
    SetHookChainArg(2, ATYPE_BOOL, false);
    rg_give_item(this, WPN_KNIFE, GT_REPLACE);

    static wpn_idName[65];
    if (TryGetWeaponIdByLevel(playerLevels[this], wpn_idName, 64))
    {
        // RemoveAllWeapons(this, bool:is_user_bot(this));
        // if (is_user_bot(id)) rg_remove_all_items(id, false);
        SetPlayerWeapon(this, wpn_idName);
    }
    else
    {
        // rg_give_default_items(this);
    }

    return HC_CONTINUE;
}

public HookChain_PlayerCanPickup(const player, const itemId)
{
    if (is_givingWpn[player]) return HC_CONTINUE;
    static ptr, classname[65];
    pev(itemId, pev_classname, ptr, classname, 64);
    if (ptr != 0)
    {
        if (equali(classname, WPN_KNIFE)) return HC_CONTINUE;

        static wpn_idName[65];
        if (TryGetWeaponIdByLevel(playerLevels[player], wpn_idName, 64) && equali(classname, wpn_idName))
        {
            SetHookChainReturn(ATYPE_INTEGER, 1);
            return HC_SUPERCEDE;
        }
        SetHookChainReturn(ATYPE_INTEGER, 0);
        return HC_SUPERCEDE;
        // console_print(player, "pev id: %s", classname);
    }
    return HC_CONTINUE;
}

public HookChain_PlayerThrowGrenade(const index, Float:vecStart[3], Float:vecVelocity[3], Float:time, const team, const usEvent)
{
    if (is_user_alive(index))
    {
        set_task(cvar_nadeRefill, "Task_RefillThrownGrenade", index + TASK_REFILL_THROWN_GRENADE);
        // a
    }
    // s
}

public OnCvarChanged(pcvar, const oldVal[], const newVal[])
{
    if (pcvar == pcvar_ffa)
    {
        is_ffa = bool:(str_to_num(newVal) != 0);
        if (phc_SpawnSpot)
        {
            if (is_ffa && g_iTotalPoints > 0)
            {
                EnableHookChain(phc_SpawnSpot);
            }
            else
            {
                DisableHookChain(phc_SpawnSpot);
            }
        }
    }
    else if (pcvar_respawn)
    {
        if (!has_nativeRespawn)
        {
            cvar_respawn = str_to_num(newVal);
        }
    }
}

stock bool:TryParseFloat(const str[], &Float:output, bool:allowNum = false)
{
    if (allowNum)
    {
        if (is_str_num(str))
        {
            output = Float:str_to_num(str);
            return true;
        }

        new c, i = 0, dot_count = 0;
        while (isalnum(c = str[i++]))
        {
            if (!isdigit(c))
            {
                if (c == '.')
                {
                    dot_count++;
                    if (dot_count >= 2)
                    {
                        output = 0.0;
                        return false;
                    }
                }
            }
        }
        output = str_to_float(str);
        return true;
    }
    else
    {
        if (is_str_num(str))
        {
            output = 0.0;
            return false;
        }

        new c, i = 0, dot_count = 0;
        while (isalnum(c = str[i++]))
        {
            if (!isdigit(c))
            {
                if (c == '.')
                {
                    dot_count++;
                    if (dot_count >= 2)
                    {
                        output = 0.0;
                        return false;
                    }
                }
            }
        }
        output = str_to_float(str);
        return true;
    }

    output = 0.0;
    return false;
}

public Cvar_Frozen(pcvar, const oldVal[], const newVal[])
{
    if (!tb_frozenCvar || equal(oldVal, newVal)) return;
    
    static sKey[4];
    if (num_to_str(pcvar, sKey, 3))
    {
        static arr[dataFreezeCVarValue];
        if (TrieGetArray(tb_frozenCvar, sKey, arr, dataFreezeCVarValue))
        {
            if (equali(newVal, arr[frozencvar_value]))
            {
                return;
            }
        }
        else
        {
            return;
        }
    }

    new arr[dataFreezeCVarValue];
    arr[frozencvar_pcvar] = pcvar;
    arr[frozencvar_length] = copy(arr[frozencvar_value], charsmax(arr[frozencvar_value]), oldVal);
    set_task(0.1, "Task_FreezeCVarValue", _, arr, dataFreezeCVarValue);
}

public Task_FreezeCVarValue(data[dataFreezeCVarValue], taskid)
{
    if (data[frozencvar_pcvar] != 0)
    {
        set_pcvar_string(data[frozencvar_pcvar], data[frozencvar_value]);
    }
}

public Ham_PreventExecute(this)
{
    if (!is_user_bot(this)) return HAM_SUPERCEDE;
    return HAM_IGNORED;
}

public OnNewRound()
{
    if (f_gameState != state_ended) return;

    f_gameState = state_begin;
    OnGameStarting();
}

public OnRoundStart()
{
    if (f_gameState != state_begin) return;

    f_gameState = state_ongoing;

    static const target[] = "armoury_entity";
    new ent = -1;
    while ((ent = rg_find_ent_by_class(ent, target, true)) > 0)
    {
        fm_remove_entity(ent);
    }

    OnGameStarted();
}

public OnRoundEnd()
{
    // new bool:result = bool:GetHookChainReturn(ATYPE_BOOL, ret);
    // console_print(0, "Round End return result: %i", result);
    OnGameEnded();
    SetHookChainReturn(ATYPE_BOOL, 0);
    return HC_SUPERCEDE;
}

public OnGetPlayerSpawnSpot(const pPlayer)
{
	if (is_ffa && RandomSpawn(pPlayer))
	{
		SetHookChainReturn(ATYPE_INTEGER, pPlayer);
		return HC_SUPERCEDE;
	}

	return HC_CONTINUE;
}

public OnDeadPlayerDropItems(const this)
{
    // "this" here is the dead player
    SetHookChainReturn(ATYPE_INTEGER, GR_PLR_DROP_GUN_NO);
    return HC_SUPERCEDE;
}

public OnPlayerCanTakeDmg(const this, const pAttacker)
{
	if (this == pAttacker || !IsPlayer(pAttacker))
		return HC_CONTINUE;

	if (f_isProtected[this]) // protected attacker can't take damage
	{
		SetHookChainReturn(ATYPE_INTEGER, 0);
		return HC_SUPERCEDE;
	}

	return HC_CONTINUE;
}

/*
=======================================================================================
Private Functions
=======================================================================================
*/
OnGameStarting()
{
    console_print(0, "All levels are reseted. New round begin.");
    ForgetSavedLevels();
    for (new i = 0; i <= MAX_PLAYERS; i++)
    {
        playerLevels[i] = 0;
        playerLevelKills[i] = 0;

        if (is_user_connected(i))
        {
            StartShowScoreBoard(i);
        }
    }
    DisableBuyZones();
    
    UTIL_RemoveFade(0, floatclamp(cvar_freezetime - 1.0, 0.0, 10.0));

    static players[MAX_PLAYERS], playerCount;
    get_players(players, playerCount, "h");
    if (playerCount > 0)
    {
        new playerId;
        for (new i = 0; i < playerCount; i++)
        {
            playerId = players[i];
            // set_pev(playerId, pev_flags, pev(playerId, pev_flags) & ~FL_FROZEN);
            // set_user_godmode(playerId, 0);
            remove_task(playerId + TASK_REFILL_THROWN_GRENADE, false);
        }
    }
}

OnGameStarted()
{
    DisableBuyZones();
    static players[MAX_PLAYERS], playerCount;
    get_players(players, playerCount, "ah");
    if (playerCount > 0)
    {
        static wpn_idName[65], playerId;
        for (new i = 0; i < playerCount; i++)
        {
            playerId = players[i];
            if (TryGetWeaponIdByLevel(playerLevels[playerId], wpn_idName, 64))
            {
                if (is_user_bot(playerId))
                {
                    RemoveAllWeapons(playerId, true);
                    SetPlayerWeapon(playerId, wpn_idName);
                    engclient_cmd(playerId, wpn_idName);
                }
                else
                {
                    RemoveAllWeapons(playerId);
                    SetPlayerWeapon(playerId, wpn_idName);
                }
            }
        }
    }
}

OnGameEnded(winnerId = 0)
{
    if (f_gameState != state_ongoing) return;

    f_gameState = state_ended;
    new ret = 1;
    if (ExecuteForward(fwh_gg_matchend, ret, winnerId) == 0)
    {
        ret = 1;
    }
    if (ret <= 1)
    {
        StopShowScoreBoard(0);
        for (new i = 1; i <= MAX_PLAYERS; i++)
        {
            if (is_user_connected(i))
            {
                // set_user_godmode(i, 1);
                remove_task(i + TASK_REFILL_THROWN_GRENADE, false);
            }
            if (is_user_alive(i))
            {
                RemoveAllWeapons(i, true);
                // set_pev(i, pev_flags, pev(i, pev_flags) | FL_FROZEN);
            }
        }
        /*
        for (new i = 1; i <= MAX_PLAYERS; i++)
        {
            if (is_user_connected(i))
            {
                set_user_godmode(i, 1);
            }
            if (is_user_alive(i))
            {
                set_pev(i, pev_flags, pev(i, pev_flags) | FL_FROZEN);
            }
        }
        */

        // Unfreeze
        /*
        for (new i = 1; i <= MAX_PLAYERS; i++)
        {
            if (is_user_alive(i))
            {
                set_pev(i, pev_flags, pev(i, pev_flags) & ~FL_FROZEN);
            }
        }
        */

        UTIL_FadeToBlack(0, 5.0);
        DisplayEndgameScoreBoard(winnerId);
        
        set_task(11.0, "Task_rg_restart_round");
        // rg_round_end(11.0, WINSTATUS_DRAW, ROUND_GAME_OVER, "Round ended", _, true);
    }
}

public Task_StopSpawnProtection(taskId)
{
    new playerId = taskId - TASK_SPAWN_PROTECTION;
    f_isProtected[playerId] = false;
}

public Task_rg_restart_round()
{
    if (phc_RoundEnd)
    {
        DisableHookChain(phc_RoundEnd);
        rg_restart_round();
        EnableHookChain(phc_RoundEnd);
    }
    else
    {
        rg_restart_round();
    }
}

ForgetSavedLevels()
{
    TrieDestroy(playerSavedLevels);
    playerSavedLevels = TrieCreate();
}

OnLevelUp(id, levelBefore, levelAfter)
{
    if (f_gameState != state_ongoing) return;
    
    if (is_user_alive(id))
    {
        static wpn_idName[65];
        static size = charsmax(wpn_idName);
        new wpnBefore = get_user_weapon(id);
        /*
        if (TryGetWeaponIdByLevel(levelBefore, wpn_idName, size))
        {
            
            if (is_user_bot(id))
            {
                rg_remove_all_items(id, false);
                console_print(0, "Stripped %s of %n", wpn_idName, id);
            }
            else if (rg_remove_item(id, wpn_idName, true))
            {
                console_print(0, "Stripped %s of %n", wpn_idName, id);
            }
            else
            {
                console_print(0, "Failed to strip %s of %n", wpn_idName, id);
            }
        }
        */
        
        new isBot = is_user_bot(id);
        RemoveAllWeapons(id, bool:isBot);
        if (TryGetWeaponIdByLevel(levelAfter, wpn_idName, size))
        {
            SetPlayerWeapon(id, wpn_idName);
            /*
            if (isBot || wpnBefore != CSW_KNIFE)
            {
                engclient_cmd(id, wpn_idName);
            }
            */
        }
    }
    if (fwh_gg_levelup)
    {
        ExecuteForward(fwh_gg_levelup, _, id, levelBefore, levelAfter);
    }
}

stock StartShowScoreBoard(id)
{
    if (id == 0 || f_gameState == state_ended || is_user_bot(id)) return;
    UpdateScoreBoardSingle(id);
    set_task(hudRefreshRate, "Task_UpdateScoreBoardSingle", id + TASK_DISPLAYHUD_ALIVE, _, _, "b");
}

stock StopShowScoreBoard(id, bool:immediatelyClear = false)
{
    if (id == 0)
    {
        for (new i = 1; i <= MAX_PLAYERS; i++)
        {
            remove_task(i + TASK_DISPLAYHUD_ALIVE, false);
        }
    }
    else
    {
        remove_task(id + TASK_DISPLAYHUD_ALIVE, false);
    }
    if (immediatelyClear && !is_user_bot(id))
    {
        ClearSyncHud(id, hudSyncChannels[Channel_Scoreboard]);
    }
}

public Task_UpdateScoreBoardSingle(taskId)
{
    new playerId = taskId - TASK_DISPLAYHUD_ALIVE;
    if (!is_user_alive(playerId) || f_gameState == state_ended) return;
    UpdateScoreBoardSingle(playerId);
}

public Task_RefillThrownGrenade(taskId)
{
    new playerId = taskId - TASK_REFILL_THROWN_GRENADE;
    if (is_user_alive(playerId))
    {
        // rg_get_user_bpammo(playerId, WEAPON_HEGRENADE);
        static wpn_idName[65];
        if (!user_has_weapon(playerId, CSW_HEGRENADE) && TryGetWeaponIdByLevel(playerLevels[playerId], wpn_idName, 64))
        {
            rg_give_item(playerId, wpn_idName, GT_REPLACE);
        }
        // playerId
    }
}

stock DisplayEndgameScoreBoard(winnerPlayerId)
{
    if (winnerPlayerId == 0)
    {
        static players[MAX_PLAYERS];
        new playerCount;
        get_players(players, playerCount, "h");
        if (playerCount > 0)
        {
            new currentId = 0;
            for (new i = 0; i < playerCount; i++)
            {
                currentId = players[i];
                if (playerLevels[currentId] == playerLevels[winnerPlayerId])
                {
                    if (playerLevelKills[currentId] == playerLevelKills[winnerPlayerId])
                    {
                        if (get_user_frags(currentId) > get_user_frags(winnerPlayerId))
                        {
                            winnerPlayerId = currentId;
                        }
                    }
                    else if (playerLevelKills[currentId] > playerLevelKills[winnerPlayerId])
                    {
                        winnerPlayerId = currentId;
                    }
                }
                else if (playerLevels[currentId] > playerLevels[winnerPlayerId])
                {
                    winnerPlayerId = currentId;
                }
            }
        }
    }
    set_hudmessage(hudColors[0], hudColors[1], hudColors[2], -1.0, -1.0, 0, 6.0, 9.0, 0.0, 2.0);
    if (winnerPlayerId == 0)
    {
        ShowSyncHudMsg(0, hudSyncChannels[Channel_Scoreboard], "The game has ended without a winner.^nThe game will restart shortly.");
    }
    else
    {
        ShowSyncHudMsg(0, hudSyncChannels[Channel_Scoreboard], "%n has won the game.^nThe game will restart shortly.", winnerPlayerId);
    }
}

stock UpdateScoreBoardSingle(player)
{
    static _struct[gg_table_weapon_data];
    if (TryGetTableLevel(playerLevels[player], _struct))
    {
        static const msg[] = "Level: %i/%i [%s - %i/%i]^nNext weapon: %s";
        static nextName[65];
        if (!TryGetWeaponIdByLevel(playerLevels[player] + 1, nextName, 64))
        {
            format(nextName, 64, "N/A");
        }
        // rg_get_weapon_info(const weapon_id, WI_NAME, const output[], maxlenght);
        set_hudmessage(hudColors[0], hudColors[1], hudColors[2], -1.0, 0.02, 0, 6.0, hudRefreshRate + (hudRefreshRate * 0.1), 0.0, 0.0);
        ShowSyncHudMsg(player, hudSyncChannels[Channel_Scoreboard], msg,
            playerLevels[player] + 1,
            TableLevelCount(),
            _struct[tb_wpn_id],
            playerLevelKills[player],
            _struct[tb_wpn_kills],
            nextName);
    }
    else
    {
        set_hudmessage(hudColors[0], hudColors[1], hudColors[2], -1.0, 0.02, 0, 6.0, hudRefreshRate + (hudRefreshRate * 0.1), 0.0, 0.0);
        ShowSyncHudMsg(player, hudSyncChannels[Channel_Scoreboard], "Your level is at the final. One more kill and you're win.");
    }
}

SetPlayerWeapon(id, const weaponIdName[])
{
    if (equal(weaponIdName, WPN_KNIFE))
    {
        return;
    }
    else
    {
        is_givingWpn[id] = true;
        if (rg_give_item(id, weaponIdName, GT_REPLACE))
        {
            if (!user_has_weapon(id, CSW_KNIFE) && (cs_get_weapon_class(get_weaponid(weaponIdName)) == CS_WEAPONCLASS_GRENADE))
            {
                rg_give_item(id, WPN_KNIFE, GT_REPLACE);
            }
            console_print(0, "Gave %n weapon %s", id, weaponIdName);
            // leayal_wpn_give(); For later
        }
        else
        {
            console_print(0, "Failed to give %n weapon %s", id, weaponIdName);
        }
        is_givingWpn[id] = false;
    }
}

bool:TryGetWeaponIdByLevel(level, wpn_idName[], bufferSize)
{
    static _struct[gg_table_weapon_data];
    if (TryGetTableLevel(level, _struct))
    {
        copy(wpn_idName, bufferSize, _struct[tb_wpn_id]);
        return true;
    }
    else
    {
        return false;
    }
}

stock bool:TryGetTableLevel(level, any:output[], size = -1)
{
    if (!tb_level || level < 0) return false;

    if (level < ArraySize(tb_level))
    {
        if (ArrayGetArray(tb_level, level, output, size))
        {
            return true;
        }
        else
        {
            return false;
        }
    }
    else
    {
        return false;
    }
}

stock TableLevelCount()
{
    if (!tb_level) return 0;

    return ArraySize(tb_level);
}

stock RemoveAllWeapons(id, bool:stripKnife = false)
{
    stripKnife = false; // Don't strip knives anymore.
    if (stripKnife)
    {
        rg_remove_all_items(id);
        // set_pdata_int(id, 116, 0);
    }
    else
    {
        rg_remove_items_by_slot(id, PRIMARY_WEAPON_SLOT);
        rg_remove_items_by_slot(id, PISTOL_SLOT);
        rg_remove_items_by_slot(id, GRENADE_SLOT);
        rg_remove_items_by_slot(id, C4_SLOT);
    }
}

stock DisableBuyZones()
{
    new ent = -1;
    while ((ent = rg_find_ent_by_class(ent, Func_BuyZone, true)))
    {
        set_pev(ent , pev_solid, SOLID_NOT);
    }
}

stock EnableBuyZones()
{
    new ent = -1;
    while ((ent = rg_find_ent_by_class(ent, Func_BuyZone, true)))
    {
        set_pev(ent , pev_solid, SOLID_TRIGGER);
    }
}

bool:RandomSpawn(const pPlayer)
{
	if(!g_iTotalPoints || g_bFirstSpawn[pPlayer])
		return false;

	new iRand = random(g_iTotalPoints), iAttempts, iLast = g_iLastSpawnIndex[pPlayer];
	do
	{
		iAttempts++;
		 /* && IsHullVacant(g_vecSpotOrigin[iRand], HULL_HUMAN, DONT_IGNORE_MONSTERS) */
		if(iRand != iLast && !IsVectorZero(g_vecSpotOrigin[iRand]) && !CheckDistance(pPlayer, g_vecSpotOrigin[iRand]))
		{
			SetPlayerPosition(pPlayer, g_vecSpotOrigin[iRand], g_vecSpotVAngles[iRand]);
			g_iLastSpawnIndex[pPlayer] = iRand;

			return true;
		}

		if(iRand++ > g_iTotalPoints) {
			iRand = random(g_iTotalPoints);
		}

	} while(iAttempts <= g_iTotalPoints);
	
	return false;
}

bool:CheckDistance(const pPlayer, const Float:vecOrigin[coordinate])
{
	new pEntity = NULLENT;
	while((pEntity = engfunc(EngFunc_FindEntityInSphere, pEntity, vecOrigin, MIN_SPAWN_RADIUS)))
	{
		if(IsPlayer(pEntity) && pEntity != pPlayer && get_entvar(pEntity, var_deadflag) == DEAD_NO) {
			// server_print("Client %i fount! skip...", pEntity)
			return true;
		}
	}
	
	return false;
}

SetPlayerPosition(const pPlayer, const Float:vecOrigin[coordinate], const Float:vecAngles[coordinate])
{
    engfunc(EngFunc_SetOrigin, pPlayer, vecOrigin);
    set_pev(pPlayer, pev_velocity, VECTOR_ZERO);
    set_pev(pPlayer, pev_v_angle, VECTOR_ZERO);
    set_pev(pPlayer, pev_angles, VECTOR_ZERO);

    set_pev(pPlayer, pev_punchangle, VECTOR_ZERO);
	set_pev(pPlayer, pev_fixangle, 1);
}

LoadPoints()
{
	new pFile;
	if(!(pFile = fopen(g_szSpawnFile, "rt")))
	{
		console_print(0, "No spawn points file found ^"%s^"", g_szMapName);
		return;
	}

	new szDatas[64], szOrigin[coordinate][6], szTeam[3], szAngles[coordinate][6], szVAngles[coordinate][6];
	while(!feof(pFile))
	{
		fgets(pFile, szDatas, charsmax(szDatas));
		trim(szDatas);

		if(!szDatas[0] || szDatas[0] == ';')
			continue;

		if(parse(szDatas, 
					szOrigin[X], 5, szOrigin[Y], 5, szOrigin[Z], 5, 
					szAngles[X], 5, szAngles[Y], 5, szAngles[Z], 5,
					szTeam, charsmax(szTeam), // ignore team param 7
					szVAngles[X], 5, szVAngles[Y], 5, szVAngles[Z], 5
				) != 10) 
		{
			continue; // ignore invalid lines
		}

		if(g_iTotalPoints >= MAX_SPAWNS)
		{
			console_print(0, "Max limit %d reached!", MAX_SPAWNS);
			break;
		}

		g_vecSpotOrigin[g_iTotalPoints][X] = str_to_float(szOrigin[X]);
		g_vecSpotOrigin[g_iTotalPoints][Y] = str_to_float(szOrigin[Y]);
		g_vecSpotOrigin[g_iTotalPoints][Z] = str_to_float(szOrigin[Z]);

		g_vecSpotAngles[g_iTotalPoints][X] = str_to_float(szAngles[X]);
		g_vecSpotAngles[g_iTotalPoints][Y] = str_to_float(szAngles[Y]);
		// g_vecSpotAngles[g_iTotalPoints][Z] = str_to_float(szAngles[Z]);

		g_vecSpotVAngles[g_iTotalPoints][X] = str_to_float(szVAngles[X]);
		g_vecSpotVAngles[g_iTotalPoints][Y] = str_to_float(szVAngles[Y]);
		// g_vecSpotVAngles[g_iTotalPoints][Z] = str_to_float(szVAngles[Z]);

		g_iTotalPoints++;
	}
	if (g_iTotalPoints)
	{
		console_print(0, "Loaded %d spawn points for map ^"%s^"", g_iTotalPoints, g_szMapName);
        if (is_ffa && phc_SpawnSpot) EnableHookChain(phc_SpawnSpot);
	}

	fclose(pFile);
}

#if defined TEST
public ClCmd_DEBUG_LevelUp(const player)
{
    static players[MAX_PLAYERS];
    new playerCount;
    get_players(players, playerCount);
    for (new i = 0; i < playerCount; i++)
    {
        playerLevelKills[players[i]] = 0;
        new level_before = playerLevels[players[i]];
        playerLevels[players[i]]++;
        OnLevelUp(players[i], level_before, playerLevels[players[i]]);
    }
}
#endif
