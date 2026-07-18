//
// Crossfire-specific tactical behavior.
//

#include <string.h>
#include <math.h>

#include <extdll.h>
#include <dllapi.h>
#include <h_export.h>
#include <meta_api.h>

#include "bot.h"
#include "bot_trace.h"
#include "bot_weapons.h"
#include "waypoint.h"
#include "util.h"
#include "map_profile_crossfire.h"

extern bot_t bots[32];
extern bot_weapon_t weapon_defs[MAX_WEAPONS];
extern WAYPOINT waypoints[MAX_WAYPOINTS];
extern int num_waypoints;

static const float CROSSFIRE_STRIKE_DURATION = 65.0f;
static const float CROSSFIRE_FIRST_BOT_STRIKE_MIN = 190.0f;
static const float CROSSFIRE_FIRST_BOT_STRIKE_MAX = 260.0f;
static const float CROSSFIRE_REPEAT_BOT_STRIKE_MIN = 240.0f;
static const float CROSSFIRE_REPEAT_BOT_STRIKE_MAX = 360.0f;
static const float CROSSFIRE_ACTIVATOR_TIMEOUT = 120.0f;
static const float CROSSFIRE_TRIGGER_TOUCH_DISTANCE = 160.0f;
static const float CROSSFIRE_SHAFT_LADDER_TAKEOVER_DISTANCE = 384.0f;
static const float CROSSFIRE_SHAFT_LADDER_MAX_HORIZONTAL_DISTANCE = 192.0f;
static const float CROSSFIRE_SHAFT_LADDER_COMBAT_LOCK_DISTANCE = 320.0f;
static const float CROSSFIRE_SHAFT_LADDER_APPROACH_SPEED = 80.0f;
static const float CROSSFIRE_SHAFT_RAMP_START_SPEED = 180.0f;
static const float CROSSFIRE_SHAFT_RAMP_CLIMB_SPEED = 120.0f;
static const float CROSSFIRE_SHAFT_LANDING_SPEED = 70.0f;
static const float CROSSFIRE_SHAFT_RAMP_STAGE_DISTANCE = 48.0f;
static const float CROSSFIRE_SHAFT_LANDING_DISTANCE = 24.0f;
static const float CROSSFIRE_SHAFT_ROOF_MOVE_SPEED = 80.0f;
static const float CROSSFIRE_SHAFT_DROP_MOVE_SPEED = 80.0f;
static const float CROSSFIRE_SHAFT_ROOF_DISTANCE = 56.0f;
static const float CROSSFIRE_SHAFT_JUMP_DISTANCE = 80.0f;
static const float CROSSFIRE_SHAFT_LANDED_HEIGHT = -1450.0f;
static const float CROSSFIRE_SHAFT_INGRESS_MAX_Y = -1900.0f;
static const float CROSSFIRE_SHAFT_PROGRESS_LOG_INTERVAL = 10.0f;
static const float CROSSFIRE_SHAFT_ROOF_SCAN_TIME = 0.35f;
static const float CROSSFIRE_SHAFT_ROOF_COVER_FIRE_TIME = 1.5f;
static const float CROSSFIRE_TOWER_DOOR_CLOSE_TIME = 47.0f;
static const float CROSSFIRE_TOWER_DOOR_ESCAPE_RESERVE = 8.0f;
static const float CROSSFIRE_BUNKER_WATCH_INTERVAL = 2.5f;
static const float CROSSFIRE_MAIN_DOOR_PREEMPT_TIME = 17.0f;
static const float CROSSFIRE_MAIN_DOOR_MOVEMENT_EPSILON = 1.0f;
static const float CROSSFIRE_CROSSBOW_ZONE_RADIUS = 560.0f;
static const float CROSSFIRE_CROSSBOW_ZONE_HEIGHT = 160.0f;
static const float CROSSFIRE_CROSSBOW_HOLD_RADIUS = 420.0f;
static const float CROSSFIRE_CROSSBOW_HOLD_HEIGHT = 96.0f;
static const float CROSSFIRE_CROSSBOW_HOLD_ARRIVAL_DISTANCE = 72.0f;
static const float CROSSFIRE_CROSSBOW_HOLD_MIN_TIME = 8.0f;
static const float CROSSFIRE_CROSSBOW_HOLD_MAX_TIME = 15.0f;
static const float CROSSFIRE_CROSSBOW_HOLD_RETRY_DELAY = 8.0f;
static const float CROSSFIRE_CROSSBOW_NO_TARGET_TIMEOUT = 4.0f;
static const float CROSSFIRE_CROSSBOW_CRITICAL_HEALTH = 25.0f;
static const float CROSSFIRE_CROSSBOW_COVER_TRACE_DISTANCE = 96.0f;
static const float CROSSFIRE_CROSSBOW_MAX_TARGET_DISTANCE = 2600.0f;
static const float CROSSFIRE_GAUSS_HOLD_ARRIVAL_DISTANCE =
   BOT_GAUSS_OVERWATCH_ARRIVAL_DISTANCE;
static const float CROSSFIRE_GAUSS_HOLD_MIN_TIME = 15.0f;
static const float CROSSFIRE_GAUSS_HOLD_MAX_TIME = 30.0f;
static const float CROSSFIRE_GAUSS_HOLD_RETRY_DELAY = 10.0f;
static const float CROSSFIRE_GAUSS_NO_TARGET_TIMEOUT = 10.0f;
static const float CROSSFIRE_RECENT_STUCK_WINDOW = 1.25f;
static const float CROSSFIRE_STUCK_CONFIRM_TIME = 2.0f;
static const float CROSSFIRE_GAUSS_CRITICAL_HEALTH = 25.0f;
static const float CROSSFIRE_GAUSS_MIN_ELEVATION = 120.0f;
static const float CROSSFIRE_GAUSS_CENTRAL_YARD_HEIGHT = -1720.0f;
static const float CROSSFIRE_GAUSS_RESERVATION_RADIUS = 360.0f;
static const float CROSSFIRE_GAUSS_RECOIL_DISTANCE = 128.0f;
static const float CROSSFIRE_GAUSS_RECOIL_DROP_DEPTH = 96.0f;
static const float CROSSFIRE_GAUSS_SIDE_FLOOR_OFFSET = 32.0f;
static const float CROSSFIRE_GAUSS_MAX_TARGET_DISTANCE = 3000.0f;
static const int CROSSFIRE_GAUSS_MIN_VISIBLE_LANES = 2;
static const int CROSSFIRE_GAUSS_HOLD_START_MIN_AMMO =
   BOT_GAUSS_SECONDARY_MIN_AMMO * 3;
static const float CROSSFIRE_SATELLITE_STRONGHOLD_MIN_X = -1040.0f;
static const float CROSSFIRE_SATELLITE_STRONGHOLD_MAX_X = -640.0f;
static const float CROSSFIRE_SATELLITE_STRONGHOLD_MIN_Y = 128.0f;
static const float CROSSFIRE_SATELLITE_STRONGHOLD_MAX_Y = 1340.0f;
static const float CROSSFIRE_SATELLITE_STRONGHOLD_MIN_Z = -1540.0f;
static const float CROSSFIRE_SATELLITE_STRONGHOLD_MAX_Z = -1450.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_AMMO_SCAN_INTERVAL = 0.25f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_STATION_USE_DISTANCE = 112.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_PICKUP_APPROACH_DISTANCE =
   320.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_ARRIVAL_DISTANCE =
   24.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_BRIDGE_ARRIVAL_DISTANCE =
   32.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_RESOURCE_RADIUS = 1600.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_FALLBACK_HYSTERESIS = 160.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_WEAPON_RETRY_TIME = 0.35f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_CROSSBOW_DISTANCE = 720.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_MP5_DISTANCE = 560.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_STRIKE_EGRESS_X = -560.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_STRIKE_DROP_Z = -1580.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_STRIKE_JUMP_INTERVAL = 0.55f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_MOVE_TURN_LIMIT = 45.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_SUMMARY_INTERVAL = 60.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_SCAN_TIME = 8.0f;
static const int CROSSFIRE_GAUSS_STRONGHOLD_AMMO_LOW = 12;
static const int CROSSFIRE_GAUSS_STRONGHOLD_AMMO_CRITICAL = 3;
static const float CROSSFIRE_GAUSS_STRONGHOLD_HEALTH_CRITICAL = 40.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_HEALTH_LOW = 75.0f;
static const float CROSSFIRE_GAUSS_STRONGHOLD_ARMOR_LOW = 60.0f;
static const int CROSSFIRE_SATELLITE_GAUSS_STRONGHOLD_CAPACITY = 1;
static const int CROSSFIRE_GAUSS_STRONGHOLD_MAX_RESOURCES = 32;
static const int CROSSFIRE_MAX_MAIN_DOORS = 4;
static const int AMBIENT_SOUND_STOP_FLAG = (1 << 5);

enum CrossfireBunkerRoute
{
   CROSSFIRE_ROUTE_UNASSIGNED = 0,
   CROSSFIRE_ROUTE_CENTRAL,
   CROSSFIRE_ROUTE_LEFT_SHAFT,
   CROSSFIRE_ROUTE_RIGHT_SHAFT,
   CROSSFIRE_ROUTE_SHAFT_LANDED
};

enum CrossfireShaftStage
{
   CROSSFIRE_SHAFT_STAGE_NONE = 0,
   CROSSFIRE_SHAFT_STAGE_APPROACH,
   CROSSFIRE_SHAFT_STAGE_RAMP_START,
   CROSSFIRE_SHAFT_STAGE_RAMP_TOP,
   CROSSFIRE_SHAFT_STAGE_LADDER_LANDING,
   CROSSFIRE_SHAFT_STAGE_CLIMB,
   CROSSFIRE_SHAFT_STAGE_CROSS_ROOF,
   CROSSFIRE_SHAFT_STAGE_DROP,
   CROSSFIRE_SHAFT_STAGE_JUMP
};

enum CrossfirePrecisionHoldMode
{
   CROSSFIRE_PRECISION_HOLD_NONE = 0,
   CROSSFIRE_PRECISION_HOLD_CROSSBOW,
   CROSSFIRE_PRECISION_HOLD_GAUSS
};

enum CrossfireGaussStrongholdResourceType
{
   CROSSFIRE_STRONGHOLD_RESOURCE_NONE = 0,
   CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO,
   CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK,
   CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH,
   CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR,
   CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW,
   CROSSFIRE_STRONGHOLD_RESOURCE_MP5,
   CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES
};

typedef struct
{
   edict_t *entity;
   int type;
} crossfire_gauss_stronghold_resource_t;

typedef struct
{
   float route_distance;
   float elevation;
   int visible_lanes;
   int cover;
   int recoil_safe_lanes;
   int reservations;
   float score;
} crossfire_gauss_hold_score_t;

static float g_crossfire_strike_end_time = 0.0f;
static float g_crossfire_strike_start_time = 0.0f;
static float g_crossfire_next_bot_strike_time = 0.0f;
static float g_crossfire_next_trigger_touch_time = 0.0f;
static float g_crossfire_strike_activator_deadline = 0.0f;
static int g_crossfire_strike_activator = -1;
static edict_t *g_crossfire_strike_trigger = NULL;
static edict_t *g_crossfire_main_doors[CROSSFIRE_MAX_MAIN_DOORS];
static Vector g_crossfire_main_door_origins[CROSSFIRE_MAX_MAIN_DOORS];
static int g_crossfire_main_door_count = 0;
static qboolean g_crossfire_trigger_touch_logged = FALSE;
static int g_crossfire_bunker_route[32];
static int g_crossfire_shaft_stage[32];
static int g_crossfire_shaft_goal[32];
static float g_crossfire_shaft_next_progress_log[32];
static qboolean g_crossfire_shaft_roof_logged[32];
static qboolean g_crossfire_shaft_slip_logged[32];
static float g_crossfire_shaft_roof_arrival_time[32];
static float g_crossfire_shaft_roof_cover_fire_end[32];
static qboolean g_crossfire_bunker_defender_logged[32];
static qboolean g_crossfire_force_shaft_route[32];
static qboolean g_crossfire_shaft_routes_active = FALSE;
static int g_crossfire_precision_hold_mode[32];
static int g_crossfire_precision_hold_goal[32];
static float g_crossfire_precision_hold_until[32];
static float g_crossfire_precision_last_target_time[32];
static float g_crossfire_precision_hold_retry_time[32];
static float g_crossfire_precision_stuck_since[32];
static qboolean g_crossfire_precision_hold_arrived[32];
static int g_crossfire_gauss_stronghold_stage[32];
static int g_crossfire_gauss_stronghold_window_goal[32];
static int g_crossfire_gauss_stronghold_resource_goal[32];
static edict_t *g_crossfire_gauss_stronghold_resource[32];
static int g_crossfire_gauss_stronghold_resource_type[32];
static int g_crossfire_gauss_stronghold_ammo_before[32];
static float g_crossfire_gauss_stronghold_health_before[32];
static float g_crossfire_gauss_stronghold_armor_before[32];
static int g_crossfire_gauss_stronghold_weapon_ammo_before[32];
static int g_crossfire_gauss_stronghold_weapon_ammo2_before[32];
static qboolean g_crossfire_gauss_stronghold_weapon_owned_before[32];
static int g_crossfire_gauss_stronghold_last_ammo[32];
static int g_crossfire_gauss_stronghold_fallback_weapon[32];
static float g_crossfire_gauss_stronghold_next_weapon_select[32];
static int g_crossfire_gauss_stronghold_return_bridge[32];
static qboolean g_crossfire_gauss_stronghold_strike_egress[32];
static int g_crossfire_gauss_stronghold_strike_window[32];
static int g_crossfire_gauss_stronghold_strike_bridge[32];
static float g_crossfire_gauss_stronghold_strike_next_jump[32];
static float g_crossfire_gauss_stronghold_next_scan[32];
static float g_crossfire_gauss_stronghold_next_summary[32];
static float g_crossfire_gauss_stronghold_next_window_change[32];
static qboolean g_crossfire_gauss_stronghold_was_inside[32];
static float g_crossfire_gauss_stronghold_next_guard_trace[32];
static crossfire_gauss_stronghold_resource_t
   g_crossfire_gauss_stronghold_resources
      [CROSSFIRE_GAUSS_STRONGHOLD_MAX_RESOURCES];
static int g_crossfire_gauss_stronghold_resource_count = 0;
static crossfire_gauss_stronghold_stats_t
   g_crossfire_gauss_stronghold_stats;
static float g_crossfire_gauss_stronghold_stats_time = 0.0f;

static void CrossfireTacticsReset(void);
static void CrossfireTacticsOnEntitySpawn(edict_t *entity);
static void CrossfireTacticsStartFrame(void);
static void CrossfireTacticsOnAmbientSound(const char *sample, int flags);
static qboolean CrossfireTacticsIsStrikeActive(void);
static qboolean CrossfireTacticsIsBotSheltered(const bot_t &pBot);
static qboolean CrossfireTacticsIsStrategicGoal(const bot_t &pBot);
static int CrossfireTacticsFindBunkerWaypoint(const bot_t &pBot);
static qboolean CrossfireTacticsEnsureBunkerGoal(bot_t &pBot);
static qboolean CrossfireTacticsEnsureStrategicGoal(bot_t &pBot);
static qboolean CrossfireTacticsHandleBunkerShaftMovement(bot_t &pBot);
static qboolean CrossfireTacticsHandleStrikeActivatorMovement(bot_t &pBot);
static qboolean CrossfireTacticsHandleBunkerDefenseMovement(bot_t &pBot);
static qboolean CrossfireTacticsIsBotStrikeActivator(const bot_t &pBot);
static qboolean CrossfireTacticsShouldYieldToStrategicMovement(
   const bot_t &pBot);
static qboolean CrossfireTacticsShouldSuppressCombat(const bot_t &pBot);
static qboolean CrossfireTacticsIsBunkerDefender(const bot_t &pBot);
static qboolean CrossfireTacticsShouldPrioritizeCombat(const bot_t &pBot);
static qboolean CrossfireTacticsCanNoticeCombatTarget(
   const bot_t &pBot, const edict_t *target);
static void CrossfireTacticsClearPrecisionHold(
   int bot_index, const char *reason);
static qboolean CrossfireTacticsEnsurePrecisionHoldGoal(bot_t &pBot);
static qboolean CrossfireTacticsHandlePrecisionHoldMovement(bot_t &pBot);
static qboolean CrossfireTacticsIsPrecisionHoldActive(const bot_t &pBot);
static qboolean CrossfireTacticsEnsureGaussStrongholdGoal(bot_t &pBot);
static qboolean CrossfireTacticsHandleGaussStrongholdMovement(bot_t &pBot);
static qboolean CrossfireTacticsHandleGaussStrongholdStrikeEgress(
   bot_t &pBot);
static qboolean CrossfireTacticsAllowWaypoint(
   bot_t &pBot, int waypoint_index, const char *context);
static void CrossfireTacticsApplyMovementSafety(bot_t &pBot);
static int CrossfireTacticsPreferredWeapon(
   const bot_t &pBot, float target_distance);


static qboolean CrossfireTacticsIsCrossfire(void)
{
   if (gpGlobals == NULL || gpGlobals->mapname == 0)
      return FALSE;

   return stricmp(STRING(gpGlobals->mapname), "crossfire") == 0;
}


static qboolean CrossfireTacticsIsBunkerGoalWaypoint(const WAYPOINT &waypoint)
{
   const Vector &origin = waypoint.origin;

   return !(waypoint.flags & W_FL_DELETED) &&
      origin.x >= -320.0f && origin.x <= 220.0f &&
      origin.y >= -2600.0f && origin.y <= -2400.0f &&
      origin.z >= -1870.0f && origin.z <= -1770.0f;
}


static int CrossfireTacticsWaypointReservations(int waypoint_index, const bot_t &pBot)
{
   int reservations = 0;

   for (int index = 0; index < 32; index++)
   {
      if (!bots[index].is_used || &bots[index] == &pBot)
         continue;

      if (bots[index].wpt_goal_type == WPT_GOAL_BUNKER &&
          bots[index].waypoint_goal == waypoint_index)
         reservations++;
   }

   return reservations;
}


static qboolean CrossfireTacticsBotAvailable(int index)
{
   return index >= 0 && index < 32 && bots[index].is_used &&
      bots[index].pEdict != NULL && !bots[index].pEdict->free &&
      bots[index].pEdict->v.deadflag == DEAD_NO &&
      bots[index].pEdict->v.health > 0.0f;
}


static int CrossfireTacticsBotArrayIndex(const bot_t &pBot)
{
   for (int index = 0; index < 32; index++)
   {
      if (&bots[index] == &pBot)
         return index;
   }

   return -1;
}


static const char *CrossfireTacticsGaussStrongholdStageName(int stage)
{
   switch (stage)
   {
      case CROSSFIRE_GAUSS_STRONGHOLD_APPROACH: return "approach";
      case CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_HOLD: return "window_hold";
      case CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_GAUSS: return "resupply_gauss";
      case CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_HEALTH: return "resupply_health";
      case CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_ARMOR: return "resupply_armor";
      case CROSSFIRE_GAUSS_STRONGHOLD_ACQUIRE_FALLBACK: return "acquire_fallback";
      case CROSSFIRE_GAUSS_STRONGHOLD_WAIT_RESPAWN: return "wait_respawn";
      case CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW: return "return_to_window";
      case CROSSFIRE_GAUSS_STRONGHOLD_LOCAL_COVER: return "local_cover";
      default: return "none";
   }
}


static const char *CrossfireTacticsGaussStrongholdResourceName(int type)
{
   switch (type)
   {
      case CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO: return "gauss_ammo";
      case CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK: return "gauss_repickup";
      case CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH: return "health";
      case CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR: return "armor";
      case CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW: return "crossbow";
      case CROSSFIRE_STRONGHOLD_RESOURCE_MP5: return "mp5";
      case CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES: return "mp5_grenades";
      default: return "none";
   }
}


static Vector CrossfireTacticsStrongholdEntityOrigin(const edict_t *entity)
{
   if (entity == NULL)
      return Vector(0.0f, 0.0f, 0.0f);

   if (entity->v.classname != 0 &&
       strncmp(STRING(entity->v.classname), "func_", 5) == 0 &&
       entity->v.size.Length() > 0.0f)
      return (entity->v.absmin + entity->v.absmax) * 0.5f;

   return entity->v.origin;
}


static qboolean CrossfireTacticsIsOriginInsideGaussStronghold(
   const Vector &origin)
{
   return origin.x >= CROSSFIRE_SATELLITE_STRONGHOLD_MIN_X &&
      origin.x <= CROSSFIRE_SATELLITE_STRONGHOLD_MAX_X &&
      origin.y >= CROSSFIRE_SATELLITE_STRONGHOLD_MIN_Y &&
      origin.y <= CROSSFIRE_SATELLITE_STRONGHOLD_MAX_Y &&
      origin.z >= CROSSFIRE_SATELLITE_STRONGHOLD_MIN_Z &&
      origin.z <= CROSSFIRE_SATELLITE_STRONGHOLD_MAX_Z;
}


qboolean MapProfileCrossfireIsWaypointInsideGaussStronghold(
   int waypoint_index)
{
   if (waypoint_index < 0 || waypoint_index >= num_waypoints)
      return FALSE;

   const WAYPOINT &waypoint = waypoints[waypoint_index];
   if (waypoint.flags & (W_FL_DELETED | W_FL_JUMP | W_FL_LONGJUMP |
       W_FL_LADDER | W_FL_LIFT_START | W_FL_LIFT_END))
      return FALSE;

   return CrossfireTacticsIsOriginInsideGaussStronghold(waypoint.origin);
}


static qboolean CrossfireTacticsIsGaussStrongholdReserved(int bot_index)
{
   return bot_index >= 0 && bot_index < 32 &&
      g_crossfire_gauss_stronghold_stage[bot_index] !=
         CROSSFIRE_GAUSS_STRONGHOLD_NONE;
}


static qboolean CrossfireTacticsIsGaussStrongholdPersistent(int bot_index)
{
   return CrossfireTacticsIsGaussStrongholdReserved(bot_index) &&
      g_crossfire_gauss_stronghold_stage[bot_index] !=
         CROSSFIRE_GAUSS_STRONGHOLD_APPROACH;
}


qboolean MapProfileCrossfireIsGaussStrongholdActive(const bot_t &pBot)
{
   return CrossfireTacticsIsGaussStrongholdPersistent(
      CrossfireTacticsBotArrayIndex(pBot));
}


int MapProfileCrossfireGaussStrongholdStage(const bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   return bot_index >= 0 ? g_crossfire_gauss_stronghold_stage[bot_index] :
      CROSSFIRE_GAUSS_STRONGHOLD_NONE;
}


void MapProfileCrossfireGetGaussStrongholdStats(
   crossfire_gauss_stronghold_stats_t *stats)
{
   if (stats != NULL)
      *stats = g_crossfire_gauss_stronghold_stats;
}


static int CrossfireTacticsGaussStrongholdAmmo(const bot_t &pBot)
{
   const int ammo_index = weapon_defs[VALVE_WEAPON_GAUSS].iAmmo1;
   return ammo_index >= 0 && ammo_index < MAX_AMMO_SLOTS ?
      pBot.m_rgAmmo[ammo_index] : 0;
}


static int CrossfireTacticsWeaponAmmo(const bot_t &pBot, int weapon_id,
   qboolean secondary)
{
   if (weapon_id <= 0 || weapon_id >= MAX_WEAPONS)
      return 0;

   const int ammo_index = secondary ? weapon_defs[weapon_id].iAmmo2 :
      weapon_defs[weapon_id].iAmmo1;
   return ammo_index >= 0 && ammo_index < MAX_AMMO_SLOTS ?
      pBot.m_rgAmmo[ammo_index] : 0;
}


static void CrossfireTacticsSetGaussStrongholdStage(
   bot_t &pBot, int bot_index, int stage, const char *reason)
{
   const int old_stage = g_crossfire_gauss_stronghold_stage[bot_index];
   if (old_stage == stage)
      return;

   g_crossfire_gauss_stronghold_stage[bot_index] = stage;
   if (stage != CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW ||
       old_stage != CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW)
      g_crossfire_gauss_stronghold_return_bridge[bot_index] = -1;
   if (stage == CROSSFIRE_GAUSS_STRONGHOLD_WAIT_RESPAWN)
      g_crossfire_gauss_stronghold_stats.wait_respawn_entries++;
   BotTrace(pBot,
      "gauss_stronghold_stage: old=%s new=%s reason=%s",
      CrossfireTacticsGaussStrongholdStageName(old_stage),
      CrossfireTacticsGaussStrongholdStageName(stage),
      reason != NULL ? reason : "state_update");
}


static void CrossfireTacticsClearGaussStrongholdResource(int bot_index)
{
   if (bot_index < 0 || bot_index >= 32)
      return;

   bot_t &bot = bots[bot_index];
   const int resource_type =
      g_crossfire_gauss_stronghold_resource_type[bot_index];
   if (bot.pBotPickupItem ==
       g_crossfire_gauss_stronghold_resource[bot_index])
      bot.pBotPickupItem = NULL;
   if (resource_type == CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH)
      bot.b_use_health_station = FALSE;
   else if (resource_type == CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR)
      bot.b_use_HEV_station = FALSE;

   g_crossfire_gauss_stronghold_resource[bot_index] = NULL;
   g_crossfire_gauss_stronghold_resource_type[bot_index] =
      CROSSFIRE_STRONGHOLD_RESOURCE_NONE;
   g_crossfire_gauss_stronghold_resource_goal[bot_index] = -1;
   g_crossfire_gauss_stronghold_ammo_before[bot_index] = 0;
   g_crossfire_gauss_stronghold_health_before[bot_index] = 0.0f;
   g_crossfire_gauss_stronghold_armor_before[bot_index] = 0.0f;
   g_crossfire_gauss_stronghold_weapon_ammo_before[bot_index] = 0;
   g_crossfire_gauss_stronghold_weapon_ammo2_before[bot_index] = 0;
   g_crossfire_gauss_stronghold_weapon_owned_before[bot_index] = FALSE;
}


static void CrossfireTacticsRejectUnmanagedStrongholdPickup(
   bot_t &pBot, int bot_index)
{
   edict_t *pickup = pBot.pBotPickupItem;
   edict_t *managed = g_crossfire_gauss_stronghold_resource[bot_index];
   if (pickup == NULL || pickup == managed)
      return;

   BotTrace(pBot,
      "gauss_stronghold_pickup_rejected: entity=%d reason=unmanaged",
      ENTINDEX(pickup));
   pBot.pBotPickupItem = NULL;
   pBot.f_find_item = gpGlobals->time + 0.5f;
}


static void CrossfireTacticsClearGaussStronghold(
   int bot_index, const char *reason)
{
   if (bot_index < 0 || bot_index >= 32 ||
       !CrossfireTacticsIsGaussStrongholdReserved(bot_index))
      return;

   bot_t &bot = bots[bot_index];
   const qboolean strike = reason != NULL && strcmp(reason, "strike") == 0;
   if (strike)
   {
      g_crossfire_gauss_stronghold_stats.strike_exits++;
      g_crossfire_gauss_stronghold_strike_egress[bot_index] =
         bot.pEdict != NULL && !bot.pEdict->free &&
         CrossfireTacticsIsOriginInsideGaussStronghold(
            bot.pEdict->v.origin);
      g_crossfire_gauss_stronghold_strike_window[bot_index] =
         g_crossfire_gauss_stronghold_window_goal[bot_index];
      g_crossfire_gauss_stronghold_strike_bridge[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_next_jump[bot_index] =
         gpGlobals->time;
      // Preserve the current graph anchor and prevent its old timeout from
      // deleting the first authoritative evacuation goal.
      bot.f_waypoint_time = gpGlobals->time;
   }
   else
   {
      g_crossfire_gauss_stronghold_strike_egress[bot_index] = FALSE;
      g_crossfire_gauss_stronghold_strike_window[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_bridge[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_next_jump[bot_index] = 0.0f;
   }

   if (bot.pEdict != NULL && !bot.pEdict->free)
      BotTrace(bot, "gauss_stronghold_left: reason=%s",
         reason != NULL ? reason : "administrative_reset");
   CrossfireTacticsClearGaussStrongholdResource(bot_index);
   g_crossfire_gauss_stronghold_stage[bot_index] =
      CROSSFIRE_GAUSS_STRONGHOLD_NONE;
   g_crossfire_gauss_stronghold_window_goal[bot_index] = -1;
   g_crossfire_gauss_stronghold_last_ammo[bot_index] = 0;
   g_crossfire_gauss_stronghold_fallback_weapon[bot_index] = 0;
   g_crossfire_gauss_stronghold_next_weapon_select[bot_index] = 0.0f;
   g_crossfire_gauss_stronghold_return_bridge[bot_index] = -1;
   g_crossfire_gauss_stronghold_next_scan[bot_index] = 0.0f;
   g_crossfire_gauss_stronghold_next_summary[bot_index] = 0.0f;
   g_crossfire_gauss_stronghold_next_window_change[bot_index] = 0.0f;
   g_crossfire_gauss_stronghold_was_inside[bot_index] = FALSE;
   g_crossfire_gauss_stronghold_next_guard_trace[bot_index] = 0.0f;
}


static int CrossfireTacticsGaussStrongholdReservations(
   const bot_t &pBot)
{
   int reservations = 0;
   for (int index = 0; index < 32; index++)
   {
      if (&bots[index] == &pBot ||
          !CrossfireTacticsIsGaussStrongholdReserved(index) ||
          !CrossfireTacticsBotAvailable(index))
         continue;
      reservations++;
   }
   return reservations;
}


static qboolean CrossfireTacticsHasUsableCrossbow(const bot_t &pBot)
{
   if (pBot.pEdict == NULL || pBot.pEdict->free)
      return FALSE;

   bot_weapon_select_t *select = GetWeaponSelect(VALVE_WEAPON_CROSSBOW);
   if (select == NULL ||
       !BotIsCarryingWeapon(const_cast<bot_t &>(pBot),
          VALVE_WEAPON_CROSSBOW) ||
       !BotCanUseWeapon(const_cast<bot_t &>(pBot), *select))
      return FALSE;

   return IsValidPrimaryAttack(const_cast<bot_t &>(pBot), *select,
      1000.0f, 0.0f, FALSE);
}


static qboolean CrossfireTacticsHasUsableGauss(const bot_t &pBot)
{
   if (pBot.pEdict == NULL || pBot.pEdict->free)
      return FALSE;

   bot_weapon_select_t *select = GetWeaponSelect(VALVE_WEAPON_GAUSS);
   if (select == NULL ||
       !BotIsCarryingWeapon(const_cast<bot_t &>(pBot), VALVE_WEAPON_GAUSS) ||
       !BotCanUseWeapon(const_cast<bot_t &>(pBot), *select))
      return FALSE;

   return IsValidSecondaryAttack(const_cast<bot_t &>(pBot), *select,
      0.0f, 0.0f, TRUE);
}


static qboolean CrossfireTacticsCanStartGaussHold(const bot_t &pBot)
{
   if (!CrossfireTacticsHasUsableGauss(pBot))
      return FALSE;

   const int ammo_index = weapon_defs[VALVE_WEAPON_GAUSS].iAmmo1;
   return ammo_index >= 0 && ammo_index < MAX_AMMO_SLOTS &&
      pBot.m_rgAmmo[ammo_index] >= CROSSFIRE_GAUSS_HOLD_START_MIN_AMMO;
}


static qboolean CrossfireTacticsHasCloseThreat(const bot_t &pBot)
{
   if (FNullEnt(pBot.pBotEnemy))
      return FALSE;

   return (pBot.pBotEnemy->v.origin - pBot.pEdict->v.origin).Length() <
      BOT_CROSSBOW_MIN_DISTANCE;
}


static qboolean CrossfireTacticsHasImmediateDanger(const bot_t &pBot)
{
   return pBot.b_see_tripmine ||
      (pBot.f_grenade_found_time > 0.0f &&
       pBot.f_grenade_found_time + 1.0f > gpGlobals->time);
}


static int CrossfireTacticsGaussStrongholdResourceType(
   const char *classname)
{
   if (classname == NULL)
      return CROSSFIRE_STRONGHOLD_RESOURCE_NONE;
   if (stricmp(classname, "ammo_gaussclip") == 0 ||
       stricmp(classname, "ammo_uranium") == 0)
      return CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO;
   if (stricmp(classname, "weapon_gauss") == 0)
      return CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK;
   if (stricmp(classname, "item_healthkit") == 0 ||
       stricmp(classname, "func_healthcharger") == 0)
      return CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH;
   if (stricmp(classname, "item_battery") == 0 ||
       stricmp(classname, "func_recharge") == 0)
      return CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR;
   if (stricmp(classname, "weapon_crossbow") == 0)
      return CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW;
   if (stricmp(classname, "weapon_9mmAR") == 0)
      return CROSSFIRE_STRONGHOLD_RESOURCE_MP5;
   if (stricmp(classname, "ammo_ARgrenades") == 0)
      return CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES;
   return CROSSFIRE_STRONGHOLD_RESOURCE_NONE;
}


static void CrossfireTacticsRegisterGaussStrongholdResource(edict_t *entity)
{
   if (entity == NULL || entity->free || entity->v.classname == 0)
      return;

   const int type = CrossfireTacticsGaussStrongholdResourceType(
      STRING(entity->v.classname));
   if (type == CROSSFIRE_STRONGHOLD_RESOURCE_NONE ||
       !CrossfireTacticsIsOriginInsideGaussStronghold(
          CrossfireTacticsStrongholdEntityOrigin(entity)))
      return;

   for (int index = 0;
        index < g_crossfire_gauss_stronghold_resource_count; index++)
   {
      if (g_crossfire_gauss_stronghold_resources[index].entity == entity)
         return;
   }

   if (g_crossfire_gauss_stronghold_resource_count >=
       CROSSFIRE_GAUSS_STRONGHOLD_MAX_RESOURCES)
      return;

   crossfire_gauss_stronghold_resource_t &resource =
      g_crossfire_gauss_stronghold_resources
         [g_crossfire_gauss_stronghold_resource_count++];
   resource.entity = entity;
   resource.type = type;
}


static qboolean CrossfireTacticsGaussStrongholdResourceActive(
   const crossfire_gauss_stronghold_resource_t &resource)
{
   const edict_t *entity = resource.entity;
   if (entity == NULL || entity->free || entity->v.classname == 0)
      return FALSE;

   if (resource.type == CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH ||
       resource.type == CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR)
   {
      const char *classname = STRING(entity->v.classname);
      if (strncmp(classname, "func_", 5) == 0)
         return entity->v.frame == 0;
   }

   return !(entity->v.effects & EF_NODRAW) && entity->v.frame <= 0;
}


static qboolean CrossfireTacticsGaussStrongholdResourceClaimed(
   int bot_index, const edict_t *entity)
{
   for (int index = 0; index < 32; index++)
   {
      if (index == bot_index || !CrossfireTacticsBotAvailable(index))
         continue;
      if (g_crossfire_gauss_stronghold_resource[index] == entity)
         return TRUE;
   }
   return FALSE;
}


static qboolean CrossfireTacticsShouldPreservePickup(
   const bot_t &pBot, const edict_t *pickup)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (pickup == NULL || bot_index < 0 ||
       !CrossfireTacticsIsGaussStrongholdPersistent(bot_index) ||
       g_crossfire_gauss_stronghold_resource[bot_index] != pickup)
      return FALSE;

   for (int index = 0;
        index < g_crossfire_gauss_stronghold_resource_count; index++)
   {
      const crossfire_gauss_stronghold_resource_t &resource =
         g_crossfire_gauss_stronghold_resources[index];
      if (resource.entity == pickup)
         return CrossfireTacticsGaussStrongholdResourceActive(resource);
   }

   return FALSE;
}


static qboolean CrossfireTacticsGaussStrongholdWaypointMatchesResource(
   int waypoint_index, int type)
{
   const WAYPOINT &waypoint = waypoints[waypoint_index];
   switch (type)
   {
      case CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO:
         return (waypoint.flags & W_FL_AMMO) &&
            (waypoint.itemflags & W_IFL_AMMO_GAUSS);
      case CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK:
         return (waypoint.flags & W_FL_WEAPON) &&
            (waypoint.itemflags & W_IFL_GAUSS);
      case CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH:
         return (waypoint.flags & W_FL_HEALTH) != 0;
      case CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR:
         return (waypoint.flags & W_FL_ARMOR) != 0;
      case CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW:
         return (waypoint.flags & W_FL_WEAPON) &&
            (waypoint.itemflags & W_IFL_CROSSBOW);
      case CROSSFIRE_STRONGHOLD_RESOURCE_MP5:
         return (waypoint.flags & W_FL_WEAPON) &&
            (waypoint.itemflags & W_IFL_MP5);
      case CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES:
         return (waypoint.flags & W_FL_AMMO) &&
            (waypoint.itemflags & W_IFL_AMMO_ARGRENADES);
      default:
         return FALSE;
   }
}


static int CrossfireTacticsFindGaussStrongholdResourceWaypoint(
   const bot_t &pBot, const edict_t *entity, int type)
{
   const Vector origin = CrossfireTacticsStrongholdEntityOrigin(entity);
   int best_index = -1;
   float best_score = 999999.0f;

   for (int index = 0; index < num_waypoints; index++)
   {
      if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(index) ||
          !CrossfireTacticsGaussStrongholdWaypointMatchesResource(
             index, type))
         continue;

      const float physical_distance =
         (waypoints[index].origin - origin).Length();
      if (physical_distance > 192.0f)
         continue;

      float route_distance = physical_distance;
      if (pBot.curr_waypoint_index >= 0 &&
          pBot.curr_waypoint_index < num_waypoints)
      {
         route_distance = WaypointDistanceFromTo(
            pBot.curr_waypoint_index, index);
         if (route_distance >= WAYPOINT_MAX_DISTANCE)
            continue;
      }

      const float score = route_distance + physical_distance * 0.5f;
      if (score < best_score)
      {
         best_score = score;
         best_index = index;
      }
   }

   return best_index;
}


static edict_t *CrossfireTacticsFindGaussStrongholdResource(
   const bot_t &pBot, int bot_index, int type, int *waypoint_index)
{
   edict_t *best_entity = NULL;
   int best_waypoint = -1;
   float best_distance = CROSSFIRE_GAUSS_STRONGHOLD_RESOURCE_RADIUS;

   for (int index = 0;
        index < g_crossfire_gauss_stronghold_resource_count; index++)
   {
      const crossfire_gauss_stronghold_resource_t &resource =
         g_crossfire_gauss_stronghold_resources[index];
      if (resource.type != type ||
          !CrossfireTacticsGaussStrongholdResourceActive(resource) ||
          CrossfireTacticsGaussStrongholdResourceClaimed(
             bot_index, resource.entity))
         continue;

      const int goal = CrossfireTacticsFindGaussStrongholdResourceWaypoint(
         pBot, resource.entity, type);
      if (goal < 0)
         continue;

      const float distance = (CrossfireTacticsStrongholdEntityOrigin(
         resource.entity) - pBot.pEdict->v.origin).Length();
      if (distance < best_distance)
      {
         best_distance = distance;
         best_entity = resource.entity;
         best_waypoint = goal;
      }
   }

   if (waypoint_index != NULL)
      *waypoint_index = best_waypoint;
   return best_entity;
}


static qboolean CrossfireTacticsSelectGaussStrongholdResource(
   bot_t &pBot, int bot_index, int resource_type, int stage,
   const char *reason)
{
   int goal = -1;
   edict_t *entity = CrossfireTacticsFindGaussStrongholdResource(
      pBot, bot_index, resource_type, &goal);
   if (entity == NULL || goal < 0)
      return FALSE;

   CrossfireTacticsClearGaussStrongholdResource(bot_index);
   g_crossfire_gauss_stronghold_resource[bot_index] = entity;
   g_crossfire_gauss_stronghold_resource_type[bot_index] = resource_type;
   g_crossfire_gauss_stronghold_resource_goal[bot_index] = goal;
   g_crossfire_gauss_stronghold_ammo_before[bot_index] =
      CrossfireTacticsGaussStrongholdAmmo(pBot);
   g_crossfire_gauss_stronghold_health_before[bot_index] =
      pBot.pEdict->v.health;
   g_crossfire_gauss_stronghold_armor_before[bot_index] =
      pBot.pEdict->v.armorvalue;
   const int weapon_id = resource_type ==
      CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW ? VALVE_WEAPON_CROSSBOW :
      (resource_type == CROSSFIRE_STRONGHOLD_RESOURCE_MP5 ||
       resource_type == CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES ?
         VALVE_WEAPON_MP5 : 0);
   g_crossfire_gauss_stronghold_weapon_owned_before[bot_index] =
      weapon_id != 0 && BotIsCarryingWeapon(pBot, weapon_id);
   g_crossfire_gauss_stronghold_weapon_ammo_before[bot_index] =
      CrossfireTacticsWeaponAmmo(pBot, weapon_id, FALSE);
   g_crossfire_gauss_stronghold_weapon_ammo2_before[bot_index] =
      CrossfireTacticsWeaponAmmo(pBot, weapon_id, TRUE);

   pBot.pBotPickupItem = entity;
   pBot.wpt_goal_type = WPT_GOAL_GAUSS_HOLD;
   pBot.waypoint_goal = goal;
   pBot.f_waypoint_goal_time = gpGlobals->time + 2.0f;
   CrossfireTacticsSetGaussStrongholdStage(
      pBot, bot_index, stage, reason);

   BotTrace(pBot,
      "gauss_stronghold_resource: type=%s entity=%d distance=%.0f ammo_before=%d ammo_after=%d health_before=%.0f health_after=%.0f armor_before=%.0f armor_after=%.0f",
      CrossfireTacticsGaussStrongholdResourceName(resource_type),
      ENTINDEX(entity),
      (CrossfireTacticsStrongholdEntityOrigin(entity) -
         pBot.pEdict->v.origin).Length(),
      g_crossfire_gauss_stronghold_ammo_before[bot_index],
      CrossfireTacticsGaussStrongholdAmmo(pBot),
      g_crossfire_gauss_stronghold_health_before[bot_index],
      pBot.pEdict->v.health,
      g_crossfire_gauss_stronghold_armor_before[bot_index],
      pBot.pEdict->v.armorvalue);
   return TRUE;
}


static int CrossfireTacticsFindCrossbowZoneAnchor(const bot_t &pBot)
{
   int best_index = -1;
   float best_distance = CROSSFIRE_CROSSBOW_ZONE_RADIUS;

   for (int index = 0; index < num_waypoints; index++)
   {
      const WAYPOINT &waypoint = waypoints[index];
      if ((waypoint.flags & W_FL_DELETED) ||
          !(waypoint.itemflags & W_IFL_CROSSBOW))
         continue;

      const Vector offset = waypoint.origin - pBot.pEdict->v.origin;
      if (fabs(offset.z) > CROSSFIRE_CROSSBOW_ZONE_HEIGHT)
         continue;

      const float distance = offset.Make2D().Length();
      if (distance < best_distance)
      {
         best_distance = distance;
         best_index = index;
      }
   }

   return best_index;
}


static int CrossfireTacticsCountWaypointCover(
   const bot_t &pBot, const Vector &origin)
{
   static const Vector directions[] = {
      Vector(1.0f, 0.0f, 0.0f), Vector(-1.0f, 0.0f, 0.0f),
      Vector(0.0f, 1.0f, 0.0f), Vector(0.0f, -1.0f, 0.0f)
   };
   int cover = 0;
   const Vector start = origin + Vector(0.0f, 0.0f, 36.0f);

   for (int index = 0; index < 4; index++)
   {
      TraceResult trace;
      UTIL_TraceLine(start,
         start + directions[index] * CROSSFIRE_CROSSBOW_COVER_TRACE_DISTANCE,
         ignore_monsters, pBot.pEdict->v.pContainingEntity, &trace);
      if (trace.flFraction < 0.95f)
         cover++;
   }

   return cover;
}


static int CrossfireTacticsPrecisionHoldReservations(
   int waypoint_index, const bot_t &pBot)
{
   int reservations = 0;

   for (int index = 0; index < 32; index++)
   {
      if (!bots[index].is_used || &bots[index] == &pBot)
         continue;

      if (g_crossfire_precision_hold_goal[index] == waypoint_index)
         reservations++;
   }

   return reservations;
}


static int CrossfireTacticsFindCrossbowHoldWaypoint(
   const bot_t &pBot, int anchor_index)
{
   if (anchor_index < 0 || anchor_index >= num_waypoints)
      return -1;

   const Vector &anchor = waypoints[anchor_index].origin;
   int best_index = -1;
   float best_score = 999999.0f;

   for (int index = 0; index < num_waypoints; index++)
   {
      const WAYPOINT &waypoint = waypoints[index];
      if ((waypoint.flags & (W_FL_DELETED | W_FL_WEAPON | W_FL_AMMO |
             W_FL_LADDER | W_FL_JUMP | W_FL_DOOR)) ||
          fabs(waypoint.origin.z - anchor.z) >
             CROSSFIRE_CROSSBOW_HOLD_HEIGHT)
         continue;

      const float anchor_distance =
         (waypoint.origin - anchor).Make2D().Length();
      if (anchor_distance > CROSSFIRE_CROSSBOW_HOLD_RADIUS)
         continue;

      float route_distance;
      if (pBot.curr_waypoint_index >= 0 &&
          pBot.curr_waypoint_index < num_waypoints)
      {
         route_distance = WaypointDistanceFromTo(
            pBot.curr_waypoint_index, index);
         if (route_distance >= WAYPOINT_UNREACHABLE)
            continue;
      }
      else
         route_distance = (waypoint.origin - pBot.pEdict->v.origin).Length();

      const int cover = CrossfireTacticsCountWaypointCover(
         pBot, waypoint.origin);
      float score = route_distance - anchor_distance * 0.25f -
         cover * 160.0f +
         CrossfireTacticsPrecisionHoldReservations(index, pBot) * 256.0f;

      if (waypoint.flags & W_FL_AIMING)
         score -= 200.0f;
      if (waypoint.flags & W_FL_CROUCH)
         score -= 80.0f;

      if (score < best_score)
      {
         best_score = score;
         best_index = index;
      }
   }

   return best_index;
}


static Vector CrossfireTacticsGaussLaneTarget(int lane)
{
   // Named Crossfire sectors, deliberately not candidate waypoints.
   switch (lane)
   {
      case 0: return Vector(0.0f, -600.0f, -1720.0f);   // central yard
      case 1: return Vector(0.0f, 300.0f, -1720.0f);    // lower central
      case 2: return Vector(0.0f, -1250.0f, -1500.0f);  // opposite balcony
      case 3: return Vector(-850.0f, -350.0f, -1680.0f);// west ramp
      case 4: return Vector(750.0f, -1550.0f, -1760.0f);// bunker approach
      default: return Vector(650.0f, 650.0f, -1640.0f); // tower approach
   }
}


static qboolean CrossfireTacticsHasFloorBelow(
   const bot_t &pBot, const Vector &origin, float depth)
{
   TraceResult trace;
   const Vector start = origin + Vector(0.0f, 0.0f, 24.0f);
   UTIL_TraceLine(start, origin - Vector(0.0f, 0.0f, depth),
      ignore_monsters, pBot.pEdict->v.pContainingEntity, &trace);
   return !trace.fStartSolid && trace.flFraction < 0.95f;
}


static qboolean CrossfireTacticsGaussLaneVisible(
   const bot_t &pBot, const Vector &origin, const Vector &target)
{
   TraceResult trace;
   UTIL_TraceLine(origin + Vector(0.0f, 0.0f, 36.0f),
      target + Vector(0.0f, 0.0f, 36.0f), ignore_monsters,
      pBot.pEdict->v.pContainingEntity, &trace);
   return !trace.fStartSolid && trace.flFraction > 0.95f;
}


static qboolean CrossfireTacticsGaussLaneHasSafeRecoil(
   const bot_t &pBot, const Vector &origin, const Vector &target)
{
   Vector forward = target - origin;
   forward.z = 0.0f;
   if (forward.Length() < 1.0f)
      return FALSE;
   forward = forward.Normalize();

   const Vector start = origin + Vector(0.0f, 0.0f, 18.0f);
   const Vector recoil = origin - forward * CROSSFIRE_GAUSS_RECOIL_DISTANCE;
   TraceResult back_trace;
   UTIL_TraceLine(start, recoil + Vector(0.0f, 0.0f, 18.0f),
      ignore_monsters, pBot.pEdict->v.pContainingEntity, &back_trace);

   // A close backstop arrests recoil before the bot can reach an edge.
   if (!back_trace.fStartSolid && back_trace.flFraction < 0.95f)
      return TRUE;

   const Vector side(-forward.y, forward.x, 0.0f);
   static const float recoil_checks[] = { 48.0f, 88.0f, 128.0f };
   for (int index = 0; index < 3; index++)
   {
      const Vector projected = origin - forward * recoil_checks[index];
      if (!CrossfireTacticsHasFloorBelow(pBot, projected,
             CROSSFIRE_GAUSS_RECOIL_DROP_DEPTH) ||
          !CrossfireTacticsHasFloorBelow(pBot,
             projected + side * CROSSFIRE_GAUSS_SIDE_FLOOR_OFFSET,
             CROSSFIRE_GAUSS_RECOIL_DROP_DEPTH) ||
          !CrossfireTacticsHasFloorBelow(pBot,
             projected - side * CROSSFIRE_GAUSS_SIDE_FLOOR_OFFSET,
             CROSSFIRE_GAUSS_RECOIL_DROP_DEPTH))
         return FALSE;
   }

   return TRUE;
}


static qboolean CrossfireTacticsGaussStrongholdWindowReached(
   const bot_t &pBot, int window_goal)
{
   if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(window_goal))
      return FALSE;

   const Vector &origin = pBot.pEdict->v.origin;
   const float distance = (origin - waypoints[window_goal].origin).Length();
   if (distance <= CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_ARRIVAL_DISTANCE)
      return TRUE;
   if (distance > CROSSFIRE_GAUSS_HOLD_ARRIVAL_DISTANCE)
      return FALSE;

   int visible_lanes = 0;
   int recoil_safe_lanes = 0;
   for (int lane = 0; lane < 6; lane++)
   {
      const Vector target = CrossfireTacticsGaussLaneTarget(lane);
      if (!CrossfireTacticsGaussLaneVisible(pBot, origin, target))
         continue;

      visible_lanes++;
      if (CrossfireTacticsGaussLaneHasSafeRecoil(pBot, origin, target))
         recoil_safe_lanes++;
   }

   return visible_lanes >= CROSSFIRE_GAUSS_MIN_VISIBLE_LANES &&
      recoil_safe_lanes * 2 >= visible_lanes;
}


static int CrossfireTacticsGaussHoldReservations(
   int waypoint_index, const bot_t &pBot)
{
   int reservations = 0;
   for (int index = 0; index < 32; index++)
   {
      if (!bots[index].is_used || &bots[index] == &pBot ||
          g_crossfire_precision_hold_mode[index] !=
             CROSSFIRE_PRECISION_HOLD_GAUSS)
         continue;

      const int goal = g_crossfire_precision_hold_goal[index];
      if (goal < 0 || goal >= num_waypoints)
         continue;

      if ((waypoints[goal].origin - waypoints[waypoint_index].origin).
             Make2D().Length() <= CROSSFIRE_GAUSS_RESERVATION_RADIUS)
         reservations++;
   }
   return reservations;
}


static int CrossfireTacticsFindGaussHoldWaypoint(
   const bot_t &pBot, crossfire_gauss_hold_score_t *selected_score)
{
   int best_index = -1;
   float best_score = 999999.0f;
   crossfire_gauss_hold_score_t best_breakdown;
   memset(&best_breakdown, 0, sizeof(best_breakdown));

   // Prefer an unoccupied zone even when its route score is much worse.
   // If every safe reachable candidate is reserved, fall back to the normal
   // load-penalized score rather than leaving the bot without a goal.
   for (int reservation_pass = 0;
        reservation_pass < 2 && best_index == -1; reservation_pass++)
   {
      best_score = 999999.0f;
      for (int index = 0; index < num_waypoints; index++)
      {
         const WAYPOINT &waypoint = waypoints[index];
         if (waypoint.flags & (W_FL_DELETED | W_FL_WEAPON | W_FL_AMMO |
             W_FL_HEALTH | W_FL_ARMOR | W_FL_LONGJUMP |
             W_FL_LADDER | W_FL_JUMP | W_FL_DOOR |
             W_FL_LIFT_START | W_FL_LIFT_END))
            continue;

         const float elevation = waypoint.origin.z -
            CROSSFIRE_GAUSS_CENTRAL_YARD_HEIGHT;
         if (elevation < CROSSFIRE_GAUSS_MIN_ELEVATION ||
             !CrossfireTacticsHasFloorBelow(pBot, waypoint.origin, 64.0f))
            continue;

         float route_distance;
         if (pBot.curr_waypoint_index >= 0 &&
             pBot.curr_waypoint_index < num_waypoints)
         {
            route_distance = WaypointDistanceFromTo(
               pBot.curr_waypoint_index, index);
            if (route_distance >= WAYPOINT_UNREACHABLE)
               continue;
         }
         else
            route_distance =
               (waypoint.origin - pBot.pEdict->v.origin).Length();

         int visible_lanes = 0;
         int recoil_safe_lanes = 0;
         for (int lane = 0; lane < 6; lane++)
         {
            const Vector target = CrossfireTacticsGaussLaneTarget(lane);
            if (!CrossfireTacticsGaussLaneVisible(
                   pBot, waypoint.origin, target))
               continue;
            visible_lanes++;
            if (CrossfireTacticsGaussLaneHasSafeRecoil(
                   pBot, waypoint.origin, target))
               recoil_safe_lanes++;
         }

         if (visible_lanes < CROSSFIRE_GAUSS_MIN_VISIBLE_LANES ||
             recoil_safe_lanes * 2 < visible_lanes)
            continue;

         const int cover = CrossfireTacticsCountWaypointCover(
            pBot, waypoint.origin);
         const int reservations = CrossfireTacticsGaussHoldReservations(
            index, pBot);
         if (reservation_pass == 0 && reservations > 0)
            continue;

         const qboolean satellite_stronghold =
            MapProfileCrossfireIsWaypointInsideGaussStronghold(index);
         if (satellite_stronghold &&
             CrossfireTacticsGaussStrongholdReservations(pBot) >=
                CROSSFIRE_SATELLITE_GAUSS_STRONGHOLD_CAPACITY)
            continue;

         const int unsafe_lanes = visible_lanes - recoil_safe_lanes;
         float score = route_distance - elevation * 1.25f -
            visible_lanes * 150.0f - cover * 120.0f -
            recoil_safe_lanes * 140.0f + unsafe_lanes * 280.0f +
            reservations * 1200.0f;
         if (satellite_stronghold)
            score -= 4000.0f;
         if (waypoint.flags & W_FL_AIMING)
            score -= 200.0f;
         if (waypoint.flags & W_FL_CROUCH)
            score -= 80.0f;

         if (score < best_score)
         {
            best_score = score;
            best_index = index;
            best_breakdown.route_distance = route_distance;
            best_breakdown.elevation = elevation;
            best_breakdown.visible_lanes = visible_lanes;
            best_breakdown.cover = cover;
            best_breakdown.recoil_safe_lanes = recoil_safe_lanes;
            best_breakdown.reservations = reservations;
            best_breakdown.score = score;
         }
      }
   }

   if (selected_score != NULL)
      *selected_score = best_breakdown;
   return best_index;
}


static int CrossfireTacticsFindGaussStrongholdWindowWaypoint(
   const bot_t &pBot, int excluded_waypoint)
{
   int best_index = -1;
   float best_score = 999999.0f;

   for (int index = 0; index < num_waypoints; index++)
   {
      const WAYPOINT &waypoint = waypoints[index];
      if (index == excluded_waypoint ||
          !MapProfileCrossfireIsWaypointInsideGaussStronghold(index) ||
          (waypoint.flags & (W_FL_WEAPON | W_FL_AMMO |
             W_FL_HEALTH | W_FL_ARMOR)))
         continue;

      float route_distance =
         (waypoint.origin - pBot.pEdict->v.origin).Length();
      if (pBot.curr_waypoint_index >= 0 &&
          pBot.curr_waypoint_index < num_waypoints)
      {
         route_distance = WaypointDistanceFromTo(
            pBot.curr_waypoint_index, index);
         if (route_distance >= WAYPOINT_MAX_DISTANCE)
            continue;
      }

      int visible_lanes = 0;
      int recoil_safe_lanes = 0;
      for (int lane = 0; lane < 6; lane++)
      {
         const Vector target = CrossfireTacticsGaussLaneTarget(lane);
         if (!CrossfireTacticsGaussLaneVisible(
                pBot, waypoint.origin, target))
            continue;
         visible_lanes++;
         if (CrossfireTacticsGaussLaneHasSafeRecoil(
                pBot, waypoint.origin, target))
            recoil_safe_lanes++;
      }

      if (visible_lanes < CROSSFIRE_GAUSS_MIN_VISIBLE_LANES ||
          recoil_safe_lanes * 2 < visible_lanes)
         continue;

      const int cover = CrossfireTacticsCountWaypointCover(
         pBot, waypoint.origin);
      const int reservations = CrossfireTacticsGaussHoldReservations(
         index, pBot);
      float score = route_distance - visible_lanes * 180.0f -
         recoil_safe_lanes * 180.0f - cover * 100.0f +
         reservations * 1200.0f;
      if (waypoint.flags & W_FL_AIMING)
         score -= 160.0f;
      if (score < best_score)
      {
         best_score = score;
         best_index = index;
      }
   }

   return best_index;
}


static int CrossfireTacticsFindGaussStrongholdInteriorWaypoint(
   const bot_t &pBot)
{
   const Vector interior(-900.0f, 760.0f, -1500.0f);
   int best_index = -1;
   float best_score = 999999.0f;

   for (int index = 0; index < num_waypoints; index++)
   {
      const WAYPOINT &waypoint = waypoints[index];
      if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(index) ||
          (waypoint.flags & (W_FL_WEAPON | W_FL_AMMO | W_FL_HEALTH |
             W_FL_ARMOR | W_FL_AIMING)))
         continue;

      float route_distance =
         (waypoint.origin - pBot.pEdict->v.origin).Length();
      if (pBot.curr_waypoint_index >= 0 &&
          pBot.curr_waypoint_index < num_waypoints)
      {
         route_distance = WaypointDistanceFromTo(
            pBot.curr_waypoint_index, index);
         if (route_distance >= WAYPOINT_MAX_DISTANCE)
            continue;
      }

      const float score = route_distance +
         (waypoint.origin - interior).Length() * 0.75f;
      if (score < best_score)
      {
         best_score = score;
         best_index = index;
      }
   }

   return best_index;
}


static qboolean CrossfireTacticsStrongholdWeaponUsable(
   const bot_t &pBot, int weapon_id)
{
   bot_weapon_select_t *select = GetWeaponSelect(weapon_id);
   return select != NULL &&
      BotIsCarryingWeapon(const_cast<bot_t &>(pBot), weapon_id) &&
      BotCanUseWeapon(const_cast<bot_t &>(pBot), *select);
}


static void CrossfireTacticsUpdateGaussStrongholdFallback(
   bot_t &pBot, int bot_index, float target_distance)
{
   if (CrossfireTacticsGaussStrongholdAmmo(pBot) >=
       BOT_GAUSS_SECONDARY_MIN_AMMO)
   {
      g_crossfire_gauss_stronghold_fallback_weapon[bot_index] = 0;
      g_crossfire_gauss_stronghold_next_weapon_select[bot_index] = 0.0f;
      return;
   }

   const qboolean crossbow_usable =
      CrossfireTacticsStrongholdWeaponUsable(
         pBot, VALVE_WEAPON_CROSSBOW);
   const qboolean mp5_usable = CrossfireTacticsStrongholdWeaponUsable(
      pBot, VALVE_WEAPON_MP5);
   const int old_weapon =
      g_crossfire_gauss_stronghold_fallback_weapon[bot_index];
   int new_weapon = old_weapon;

   if (old_weapon == VALVE_WEAPON_CROSSBOW && crossbow_usable &&
       target_distance >= CROSSFIRE_GAUSS_STRONGHOLD_MP5_DISTANCE)
      new_weapon = old_weapon;
   else if (old_weapon == VALVE_WEAPON_MP5 && mp5_usable &&
            target_distance <=
               CROSSFIRE_GAUSS_STRONGHOLD_CROSSBOW_DISTANCE +
                  CROSSFIRE_GAUSS_STRONGHOLD_FALLBACK_HYSTERESIS)
      new_weapon = old_weapon;
   else
   {
      if (target_distance >=
             CROSSFIRE_GAUSS_STRONGHOLD_CROSSBOW_DISTANCE &&
          crossbow_usable)
         new_weapon = VALVE_WEAPON_CROSSBOW;
      else if (mp5_usable)
         new_weapon = VALVE_WEAPON_MP5;
      else if (crossbow_usable)
         new_weapon = VALVE_WEAPON_CROSSBOW;
      else
         new_weapon = 0;
   }

   if (new_weapon != old_weapon)
   {
      g_crossfire_gauss_stronghold_fallback_weapon[bot_index] = new_weapon;
      g_crossfire_gauss_stronghold_next_weapon_select[bot_index] = 0.0f;
      if (new_weapon == VALVE_WEAPON_CROSSBOW)
         g_crossfire_gauss_stronghold_stats.crossbow_fallbacks++;
      else if (new_weapon == VALVE_WEAPON_MP5)
         g_crossfire_gauss_stronghold_stats.mp5_fallbacks++;
   }

   if (new_weapon == 0)
   {
      g_crossfire_gauss_stronghold_next_weapon_select[bot_index] = 0.0f;
      return;
   }

   if (pBot.current_weapon.iId == new_weapon)
   {
      g_crossfire_gauss_stronghold_next_weapon_select[bot_index] = 0.0f;
      return;
   }
   if (g_crossfire_gauss_stronghold_next_weapon_select[bot_index] >
       gpGlobals->time)
      return;

   UTIL_SelectWeapon(pBot.pEdict, new_weapon);
   g_crossfire_gauss_stronghold_next_weapon_select[bot_index] =
      gpGlobals->time + CROSSFIRE_GAUSS_STRONGHOLD_WEAPON_RETRY_TIME;
   BotTrace(pBot,
      "gauss_stronghold_fallback: weapon=%s distance=%.0f reason=%s",
      new_weapon == VALVE_WEAPON_CROSSBOW ? "crossbow" : "mp5",
      target_distance, new_weapon == old_weapon ? "retry" : "condition");
}


static void CrossfireTacticsCompleteGaussStrongholdResource(
   bot_t &pBot, int bot_index, qboolean successful)
{
   const int type =
      g_crossfire_gauss_stronghold_resource_type[bot_index];
   edict_t *entity = g_crossfire_gauss_stronghold_resource[bot_index];
   const int ammo_after = CrossfireTacticsGaussStrongholdAmmo(pBot);
   const float health_after = pBot.pEdict->v.health;
   const float armor_after = pBot.pEdict->v.armorvalue;
   const int resource_goal =
      g_crossfire_gauss_stronghold_resource_goal[bot_index];

   if (MapProfileCrossfireIsWaypointInsideGaussStronghold(resource_goal) &&
       (pBot.pEdict->v.origin - waypoints[resource_goal].origin).Length() <=
          CROSSFIRE_GAUSS_STRONGHOLD_PICKUP_APPROACH_DISTANCE)
   {
      // Physical pickup/station steering may leave the generic navigator's
      // current node at the old firing window. Re-anchor before returning.
      pBot.curr_waypoint_index = resource_goal;
      pBot.waypoint_origin = waypoints[resource_goal].origin;
      pBot.f_waypoint_time = gpGlobals->time;
   }

   if (successful)
   {
      if (type == CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO)
         g_crossfire_gauss_stronghold_stats.gauss_ammo_pickups++;
      else if (type == CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK)
         g_crossfire_gauss_stronghold_stats.gauss_repicks++;
      else if (type == CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH)
         g_crossfire_gauss_stronghold_stats.health_pickups++;
      else if (type == CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR)
         g_crossfire_gauss_stronghold_stats.armor_pickups++;

      if ((type == CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO ||
           type == CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK) &&
          ammo_after >= BOT_GAUSS_SECONDARY_MIN_AMMO &&
          BotIsCarryingWeapon(pBot, VALVE_WEAPON_GAUSS))
         UTIL_SelectWeapon(pBot.pEdict, VALVE_WEAPON_GAUSS);
   }

   BotTrace(pBot,
      "gauss_stronghold_resource: type=%s entity=%d distance=0 ammo_before=%d ammo_after=%d health_before=%.0f health_after=%.0f armor_before=%.0f armor_after=%.0f result=%s",
      CrossfireTacticsGaussStrongholdResourceName(type),
      entity != NULL ? ENTINDEX(entity) : 0,
      g_crossfire_gauss_stronghold_ammo_before[bot_index], ammo_after,
      g_crossfire_gauss_stronghold_health_before[bot_index], health_after,
      g_crossfire_gauss_stronghold_armor_before[bot_index], armor_after,
      successful ? "acquired" : "inactive_without_gain");

   CrossfireTacticsClearGaussStrongholdResource(bot_index);
   CrossfireTacticsSetGaussStrongholdStage(pBot, bot_index,
      CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
      successful ? "resource_acquired" : "resource_unavailable");
}


static qboolean CrossfireTacticsUpdateGaussStrongholdResource(
   bot_t &pBot, int bot_index)
{
   edict_t *entity = g_crossfire_gauss_stronghold_resource[bot_index];
   if (entity == NULL)
      return FALSE;

   const int type =
      g_crossfire_gauss_stronghold_resource_type[bot_index];
   const int ammo_after = CrossfireTacticsGaussStrongholdAmmo(pBot);
   const int weapon_id = type == CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW ?
      VALVE_WEAPON_CROSSBOW :
      (type == CROSSFIRE_STRONGHOLD_RESOURCE_MP5 ||
       type == CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES ?
         VALVE_WEAPON_MP5 : 0);
   const int weapon_ammo_after =
      CrossfireTacticsWeaponAmmo(pBot, weapon_id, FALSE);
   const int weapon_ammo2_after =
      CrossfireTacticsWeaponAmmo(pBot, weapon_id, TRUE);
   const char *classname = entity->v.classname != 0 ?
      STRING(entity->v.classname) : "";
   const qboolean health_station =
      type == CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH &&
      stricmp(classname, "func_healthcharger") == 0;
   const qboolean armor_station =
      type == CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR &&
      stricmp(classname, "func_recharge") == 0;
   const qboolean health_gain = pBot.pEdict->v.health >
      g_crossfire_gauss_stronghold_health_before[bot_index];
   const qboolean armor_gain = pBot.pEdict->v.armorvalue >
      g_crossfire_gauss_stronghold_armor_before[bot_index];
   const qboolean successful =
      ((type == CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO ||
        type == CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK) &&
       ammo_after > g_crossfire_gauss_stronghold_ammo_before[bot_index]) ||
      (type == CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH &&
       health_gain && (!health_station ||
          pBot.pEdict->v.health >=
             CROSSFIRE_GAUSS_STRONGHOLD_HEALTH_LOW)) ||
      (type == CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR &&
       armor_gain && (!armor_station ||
          pBot.pEdict->v.armorvalue >=
             CROSSFIRE_GAUSS_STRONGHOLD_ARMOR_LOW)) ||
      (type == CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW &&
       BotIsCarryingWeapon(pBot, VALVE_WEAPON_CROSSBOW) &&
       (!g_crossfire_gauss_stronghold_weapon_owned_before[bot_index] ||
        weapon_ammo_after >
           g_crossfire_gauss_stronghold_weapon_ammo_before[bot_index])) ||
      (type == CROSSFIRE_STRONGHOLD_RESOURCE_MP5 &&
       BotIsCarryingWeapon(pBot, VALVE_WEAPON_MP5) &&
       (!g_crossfire_gauss_stronghold_weapon_owned_before[bot_index] ||
        weapon_ammo_after >
           g_crossfire_gauss_stronghold_weapon_ammo_before[bot_index])) ||
      (type == CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES &&
       weapon_ammo2_after >
          g_crossfire_gauss_stronghold_weapon_ammo2_before[bot_index]);

   qboolean active = FALSE;
   for (int index = 0;
        index < g_crossfire_gauss_stronghold_resource_count; index++)
   {
      if (g_crossfire_gauss_stronghold_resources[index].entity == entity)
      {
         active = CrossfireTacticsGaussStrongholdResourceActive(
            g_crossfire_gauss_stronghold_resources[index]);
         break;
      }
   }

   if (successful || !active)
   {
      CrossfireTacticsCompleteGaussStrongholdResource(
         pBot, bot_index, successful ||
            (health_station && health_gain) ||
            (armor_station && armor_gain));
      return FALSE;
   }

   pBot.pBotPickupItem = entity;
   pBot.wpt_goal_type = WPT_GOAL_GAUSS_HOLD;
   pBot.waypoint_goal =
      g_crossfire_gauss_stronghold_resource_goal[bot_index];
   pBot.f_waypoint_goal_time = gpGlobals->time + 2.0f;
   return TRUE;
}


static qboolean CrossfireTacticsGaussStrongholdStationInUseRange(
   const bot_t &pBot, int bot_index, qboolean *health_station_out,
   Vector *target_out)
{
   edict_t *entity = g_crossfire_gauss_stronghold_resource[bot_index];
   if (pBot.pEdict == NULL || entity == NULL || entity->free ||
       entity->v.classname == 0 || entity->v.frame != 0)
      return FALSE;

   const int type =
      g_crossfire_gauss_stronghold_resource_type[bot_index];
   const char *classname = STRING(entity->v.classname);
   const qboolean health_station =
      type == CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH &&
      stricmp(classname, "func_healthcharger") == 0;
   const qboolean armor_station =
      type == CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR &&
      stricmp(classname, "func_recharge") == 0;
   if (!health_station && !armor_station)
      return FALSE;

   const Vector target = CrossfireTacticsStrongholdEntityOrigin(entity);
   if ((target - pBot.pEdict->v.origin).Length() >
       CROSSFIRE_GAUSS_STRONGHOLD_STATION_USE_DISTANCE)
      return FALSE;

   if (health_station_out != NULL)
      *health_station_out = health_station;
   if (target_out != NULL)
      *target_out = target;
   return TRUE;
}


static qboolean CrossfireTacticsDriveGaussStrongholdStationUse(
   bot_t &pBot, int bot_index)
{
   qboolean health_station = FALSE;
   Vector target;
   if (!CrossfireTacticsGaussStrongholdStationInUseRange(
          pBot, bot_index, &health_station, &target))
      return FALSE;

   qboolean &using_station = health_station ?
      pBot.b_use_health_station : pBot.b_use_HEV_station;
   float &use_time = health_station ?
      pBot.f_use_health_time : pBot.f_use_HEV_time;
   if (!using_station)
      use_time = gpGlobals->time;
   using_station = TRUE;
   pBot.v_use_target = target;
   pBot.f_dont_avoid_wall_time = gpGlobals->time + 1.0f;
   pBot.f_pause_time = 0.0f;
   pBot.f_move_direction = 0.0f;
   pBot.f_move_speed = 0.0f;
   pBot.f_strafe_time = gpGlobals->time + 1.0f;
   pBot.f_strafe_direction = 0.0f;

   const Vector use_direction = target - GetGunPosition(pBot.pEdict);
   const Vector use_angles = UTIL_VecToAngles(use_direction);
   pBot.pEdict->v.idealpitch = UTIL_WrapAngle(use_angles.x);
   pBot.pEdict->v.ideal_yaw = UTIL_WrapAngle(use_angles.y);
   pBot.pEdict->v.button &= ~(IN_ATTACK | IN_ATTACK2 | IN_JUMP | IN_DUCK);
   pBot.pEdict->v.button |= IN_USE;
   return TRUE;
}


static qboolean CrossfireTacticsFinishGaussStrongholdPickupApproach(
   bot_t &pBot, int bot_index)
{
   edict_t *entity = g_crossfire_gauss_stronghold_resource[bot_index];
   if (entity == NULL || entity->free || entity->v.classname == 0 ||
       pBot.pBotEnemy != NULL)
      return FALSE;

   const char *classname = STRING(entity->v.classname);
   if (strncmp(classname, "func_", 5) == 0)
      return FALSE;

   const Vector target = CrossfireTacticsStrongholdEntityOrigin(entity);
   const Vector direction = target - pBot.pEdict->v.origin;
   if (!CrossfireTacticsIsOriginInsideGaussStronghold(target) ||
       direction.Length() >
          CROSSFIRE_GAUSS_STRONGHOLD_PICKUP_APPROACH_DISTANCE ||
       !FVisible(target, pBot.pEdict, entity))
      return FALSE;

   Vector hull_target = target;
   if (fabs(hull_target.z - pBot.pEdict->v.origin.z) <= 64.0f)
      hull_target.z = pBot.pEdict->v.origin.z;
   TraceResult hull_trace;
   UTIL_TraceHull(pBot.pEdict->v.origin, hull_target, ignore_monsters,
      human_hull, pBot.pEdict->v.pContainingEntity, &hull_trace);
   if (hull_trace.fStartSolid ||
       (hull_trace.flFraction < 0.95f && hull_trace.pHit != entity))
      return FALSE;

   const int resource_goal =
      g_crossfire_gauss_stronghold_resource_goal[bot_index];
   if (MapProfileCrossfireIsWaypointInsideGaussStronghold(resource_goal))
   {
      // Goal-directed combat steers the legs through curr_waypoint_index.
      // Re-anchor it before taking over direct movement so a stale firing
      // window cannot pull the bot away from the visible room pickup.
      pBot.curr_waypoint_index = resource_goal;
      pBot.waypoint_origin = waypoints[resource_goal].origin;
      pBot.f_waypoint_time = gpGlobals->time;
   }

   const Vector angles = UTIL_VecToAngles(direction);
   pBot.pEdict->v.ideal_yaw = UTIL_WrapAngle(angles.y);
   pBot.f_pause_time = 0.0f;
   pBot.f_move_direction = 1.0f;
   pBot.f_move_speed = pBot.f_max_speed;
   pBot.f_strafe_direction = 0.0f;
   pBot.f_dont_avoid_wall_time = gpGlobals->time + 0.5f;
   pBot.pEdict->v.button &= ~IN_JUMP;
   return TRUE;
}


static qboolean CrossfireTacticsGaussStrongholdSegmentSafe(
   const bot_t &pBot, const Vector &start, const Vector &end)
{
   if (!CrossfireTacticsIsOriginInsideGaussStronghold(start) ||
       !CrossfireTacticsIsOriginInsideGaussStronghold(end))
      return FALSE;

   TraceResult trace;
   const Vector eye_offset(0.0f, 0.0f, 36.0f);
   UTIL_TraceLine(start + eye_offset, end + eye_offset,
      ignore_monsters, pBot.pEdict->v.pContainingEntity, &trace);
   if (trace.fStartSolid || trace.flFraction < 0.95f)
      return FALSE;

   TraceResult hull_trace;
   UTIL_TraceHull(start, end, ignore_monsters, human_hull,
      pBot.pEdict->v.pContainingEntity, &hull_trace);
   if (hull_trace.fStartSolid || hull_trace.flFraction < 0.95f)
      return FALSE;

   const Vector delta = end - start;
   const float distance = delta.Make2D().Length();
   const int samples = (int)(distance / 64.0f) + 1;
   for (int index = 1; index <= samples; index++)
   {
      const float fraction = (float)index / (float)samples;
      const Vector point = start + delta * fraction;
      if (!CrossfireTacticsIsOriginInsideGaussStronghold(point) ||
          !CrossfireTacticsHasFloorBelow(pBot, point, 96.0f))
         return FALSE;
   }

   return TRUE;
}


static int CrossfireTacticsFindGaussStrongholdReturnBridge(
   const bot_t &pBot, int window_goal)
{
   const Vector &origin = pBot.pEdict->v.origin;
   const Vector &window = waypoints[window_goal].origin;
   int best_index = -1;
   float best_score = 999999.0f;

   for (int index = 0; index < num_waypoints; index++)
   {
      const WAYPOINT &waypoint = waypoints[index];
      if (index == window_goal ||
          !MapProfileCrossfireIsWaypointInsideGaussStronghold(index) ||
          (waypoint.flags & (W_FL_WEAPON | W_FL_AMMO | W_FL_HEALTH |
             W_FL_ARMOR | W_FL_AIMING | W_FL_DOOR)))
         continue;

      const float first_distance =
         (waypoint.origin - origin).Make2D().Length();
      if (first_distance <
             CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_ARRIVAL_DISTANCE ||
          first_distance > 640.0f ||
          !CrossfireTacticsGaussStrongholdSegmentSafe(
             pBot, origin, waypoint.origin) ||
          !CrossfireTacticsGaussStrongholdSegmentSafe(
             pBot, waypoint.origin, window))
         continue;

      const float score = first_distance +
         (window - waypoint.origin).Make2D().Length();
      if (score < best_score)
      {
         best_score = score;
         best_index = index;
      }
   }

   return best_index;
}


static qboolean CrossfireTacticsDriveGaussStrongholdReturn(
   bot_t &pBot, int bot_index)
{
   if (g_crossfire_gauss_stronghold_stage[bot_index] !=
       CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW)
      return FALSE;

   const int window_goal =
      g_crossfire_gauss_stronghold_window_goal[bot_index];
   if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(window_goal))
      return FALSE;
   if (CrossfireTacticsGaussStrongholdWindowReached(pBot, window_goal))
      return FALSE;

   // This route is floor-checked below and again by movement safety. Prevent
   // the earlier generic drop turn from replacing its yaw every frame.
   pBot.f_drop_check_time = gpGlobals->time + 0.5f;

   Vector target = waypoints[window_goal].origin;
   qboolean targeting_bridge = FALSE;
   int &bridge = g_crossfire_gauss_stronghold_return_bridge[bot_index];
   if (MapProfileCrossfireIsWaypointInsideGaussStronghold(bridge))
   {
      target = waypoints[bridge].origin;
      targeting_bridge = TRUE;
      if ((target - pBot.pEdict->v.origin).Make2D().Length() <=
          CROSSFIRE_GAUSS_STRONGHOLD_BRIDGE_ARRIVAL_DISTANCE)
      {
         bridge = -1;
         target = waypoints[window_goal].origin;
         targeting_bridge = FALSE;
      }
   }

   if (!targeting_bridge)
   {
      bridge = -1;
      if (!CrossfireTacticsGaussStrongholdSegmentSafe(
             pBot, pBot.pEdict->v.origin, target))
      {
         bridge = CrossfireTacticsFindGaussStrongholdReturnBridge(
            pBot, window_goal);
         if (bridge < 0)
            return FALSE;
         target = waypoints[bridge].origin;
         targeting_bridge = TRUE;
      }
   }

   const Vector direction = target - pBot.pEdict->v.origin;
   const float arrival_distance = targeting_bridge ?
      CROSSFIRE_GAUSS_STRONGHOLD_BRIDGE_ARRIVAL_DISTANCE :
      CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_ARRIVAL_DISTANCE;
   pBot.wpt_goal_type = WPT_GOAL_GAUSS_HOLD;
   pBot.waypoint_goal = targeting_bridge ? bridge : window_goal;
   pBot.f_waypoint_goal_time = gpGlobals->time + 2.0f;
   if (direction.Make2D().Length() <= arrival_distance)
   {
      if (targeting_bridge)
         bridge = -1;
      return FALSE;
   }

   // Keep the profile authoritative for the full verified room segment. The
   // generic graph clears intermediate goals at broad arrival radii and can
   // reacquire unrelated pickups, which lets the bot drift toward a drop.
   const float desired_yaw = UTIL_WrapAngle(
      UTIL_VecToAngles(direction).y);
   pBot.pEdict->v.ideal_yaw = desired_yaw;
   pBot.f_pause_time = 0.0f;
   pBot.f_move_direction = 1.0f;
   pBot.f_move_speed = pBot.f_max_speed;
   pBot.f_strafe_direction = 0.0f;
   pBot.f_dont_avoid_wall_time = gpGlobals->time + 0.5f;
   pBot.pEdict->v.button &= ~IN_JUMP;
   // Goal-directed strategic strafing uses the current route node to steer
   // the legs independently from combat aim.
   pBot.curr_waypoint_index = pBot.waypoint_goal;
   return TRUE;
}


static qboolean CrossfireTacticsHandleGaussStrongholdStrikeEgress(
   bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0 ||
       !g_crossfire_gauss_stronghold_strike_egress[bot_index])
      return FALSE;

   if (!CrossfireTacticsIsStrikeActive() || pBot.pEdict == NULL ||
       pBot.pEdict->free || pBot.pEdict->v.deadflag != DEAD_NO)
   {
      g_crossfire_gauss_stronghold_strike_egress[bot_index] = FALSE;
      g_crossfire_gauss_stronghold_strike_window[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_bridge[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_next_jump[bot_index] = 0.0f;
      return FALSE;
   }

   // Strike egress deliberately owns its verified window/drop movement.
   pBot.f_drop_check_time = gpGlobals->time + 0.5f;

   const Vector &origin = pBot.pEdict->v.origin;
   if (origin.x >= CROSSFIRE_GAUSS_STRONGHOLD_STRIKE_EGRESS_X - 8.0f ||
       origin.z <= CROSSFIRE_GAUSS_STRONGHOLD_STRIKE_DROP_Z)
   {
      g_crossfire_gauss_stronghold_strike_egress[bot_index] = FALSE;
      g_crossfire_gauss_stronghold_strike_window[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_bridge[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_next_jump[bot_index] = 0.0f;
      pBot.curr_waypoint_index = -1;
      pBot.f_waypoint_time = gpGlobals->time;
      BotTrace(pBot,
         "gauss_stronghold_strike_egress: state=complete origin=%.0f,%.0f,%.0f",
         origin.x, origin.y, origin.z);
      return FALSE;
   }

   int &window = g_crossfire_gauss_stronghold_strike_window[bot_index];
   if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(window))
      window = CrossfireTacticsFindGaussStrongholdWindowWaypoint(pBot, -1);

   qboolean outward = window < 0 ||
      CrossfireTacticsGaussStrongholdWindowReached(pBot, window);
   Vector target = outward ?
      Vector(CROSSFIRE_GAUSS_STRONGHOLD_STRIKE_EGRESS_X,
         MapProfileCrossfireIsWaypointInsideGaussStronghold(window) ?
            waypoints[window].origin.y : origin.y,
         origin.z) : waypoints[window].origin;

   int &bridge = g_crossfire_gauss_stronghold_strike_bridge[bot_index];
   if (!outward)
   {
      if (MapProfileCrossfireIsWaypointInsideGaussStronghold(bridge))
      {
         target = waypoints[bridge].origin;
         if ((target - origin).Make2D().Length() <=
             CROSSFIRE_GAUSS_STRONGHOLD_BRIDGE_ARRIVAL_DISTANCE)
         {
            bridge = -1;
            target = waypoints[window].origin;
         }
      }
      else if (!CrossfireTacticsGaussStrongholdSegmentSafe(
                  pBot, origin, target))
      {
         bridge = CrossfireTacticsFindGaussStrongholdReturnBridge(
            pBot, window);
         if (bridge >= 0)
            target = waypoints[bridge].origin;
      }
   }
   else
      bridge = -1;

   const Vector direction = target - origin;
   const float desired_yaw = UTIL_WrapAngle(
      UTIL_VecToAngles(direction).y);
   const float yaw_error = fabs(UTIL_WrapAngle(
      desired_yaw - pBot.pEdict->v.v_angle.y));
   pBot.pEdict->v.ideal_yaw = desired_yaw;
   pBot.f_pause_time = 0.0f;
   pBot.f_move_direction = 1.0f;
   pBot.f_move_speed = yaw_error <=
      CROSSFIRE_GAUSS_STRONGHOLD_MOVE_TURN_LIMIT ?
         pBot.f_max_speed : 0.0f;
   pBot.f_strafe_direction = 0.0f;
   pBot.f_dont_avoid_wall_time = gpGlobals->time + 0.5f;
   pBot.pEdict->v.button &= ~(IN_JUMP | IN_DUCK);
   pBot.curr_waypoint_index = outward ? -1 :
      (MapProfileCrossfireIsWaypointInsideGaussStronghold(bridge) ?
         bridge : window);
   if (outward)
   {
      pBot.pEdict->v.button |= IN_DUCK;
      if (pBot.f_move_speed > 0.0f &&
          g_crossfire_gauss_stronghold_strike_next_jump[bot_index] <=
             gpGlobals->time)
      {
         pBot.pEdict->v.button |= IN_JUMP;
         g_crossfire_gauss_stronghold_strike_next_jump[bot_index] =
            gpGlobals->time +
               CROSSFIRE_GAUSS_STRONGHOLD_STRIKE_JUMP_INTERVAL;
      }
   }
   return TRUE;
}


static void CrossfireTacticsSetGaussStrongholdWindowGoal(
   bot_t &pBot, int bot_index, int stage, const char *reason)
{
   CrossfireTacticsClearGaussStrongholdResource(bot_index);
   pBot.wpt_goal_type = WPT_GOAL_GAUSS_HOLD;
   const int bridge = g_crossfire_gauss_stronghold_return_bridge[bot_index];
   pBot.waypoint_goal = stage ==
         CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW &&
         MapProfileCrossfireIsWaypointInsideGaussStronghold(bridge) ?
      bridge : g_crossfire_gauss_stronghold_window_goal[bot_index];
   pBot.f_waypoint_goal_time = gpGlobals->time + 2.0f;
   pBot.pTrackSoundEdict = NULL;
   pBot.f_track_sound_time = -1.0f;
   CrossfireTacticsSetGaussStrongholdStage(
      pBot, bot_index, stage, reason);
}


static void CrossfireTacticsCompleteGaussStrongholdReturn(
   bot_t &pBot, int bot_index, int goal)
{
   if (g_crossfire_gauss_stronghold_stage[bot_index] !=
       CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW)
      return;
   if (goal != g_crossfire_gauss_stronghold_window_goal[bot_index])
      return;

   g_crossfire_gauss_stronghold_stats.returns_to_window++;
   CrossfireTacticsSetGaussStrongholdStage(pBot, bot_index,
      CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_HOLD, "window_reached");
   BotTrace(pBot,
      "gauss_stronghold_return_window: waypoint=%d route_distance=0",
      goal);
}


static qboolean CrossfireTacticsEnsureGaussStrongholdGoal(bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0 || !CrossfireTacticsIsGaussStrongholdPersistent(
          bot_index) || pBot.pEdict == NULL)
      return FALSE;

   int &window_goal =
      g_crossfire_gauss_stronghold_window_goal[bot_index];
   if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(window_goal))
   {
      window_goal = CrossfireTacticsFindGaussStrongholdWindowWaypoint(
         pBot, -1);
      if (window_goal < 0)
      {
         CrossfireTacticsClearPrecisionHold(
            bot_index, "entire_zone_unreachable");
         return FALSE;
      }
      g_crossfire_precision_hold_goal[bot_index] = window_goal;
   }

   // Generic item scanning must not override the role's staged local
   // resource target or its return route.
   CrossfireTacticsRejectUnmanagedStrongholdPickup(pBot, bot_index);

   const qboolean inside = CrossfireTacticsIsOriginInsideGaussStronghold(
      pBot.pEdict->v.origin);
   if (g_crossfire_gauss_stronghold_was_inside[bot_index] && !inside)
   {
      g_crossfire_gauss_stronghold_stats.unexpected_zone_exits++;
      if (pBot.gauss_secondary_state == BOT_GAUSS_SECONDARY_RELEASE_WAIT ||
          pBot.gauss_secondary_state == BOT_GAUSS_SECONDARY_COOLDOWN)
         g_crossfire_gauss_stronghold_stats.recoil_falls++;
      BotTrace(pBot,
         "gauss_stronghold_unexpected_exit: origin=%.0f,%.0f,%.0f",
         pBot.pEdict->v.origin.x, pBot.pEdict->v.origin.y,
         pBot.pEdict->v.origin.z);
   }
   g_crossfire_gauss_stronghold_was_inside[bot_index] = inside;

   if (!inside)
   {
      CrossfireTacticsSetGaussStrongholdWindowGoal(pBot, bot_index,
         CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
         "displaced_outside_zone");
      return TRUE;
   }

   if (pBot.wpt_goal_type == WPT_GOAL_ENEMY &&
       !MapProfileCrossfireIsWaypointInsideGaussStronghold(
          pBot.waypoint_goal))
   {
      if (g_crossfire_gauss_stronghold_next_guard_trace[bot_index] <=
          gpGlobals->time)
      {
         g_crossfire_gauss_stronghold_next_guard_trace[bot_index] =
            gpGlobals->time + 1.0f;
         g_crossfire_gauss_stronghold_stats.attempted_enemy_pursuits++;
         g_crossfire_gauss_stronghold_stats.enemy_pursuit_prevented++;
         BotTrace(pBot,
            "gauss_stronghold_exit_prevented: candidate_goal=%d candidate_origin=%.0f,%.0f,%.0f reason=enemy_pursuit",
            pBot.waypoint_goal,
            pBot.waypoint_goal >= 0 && pBot.waypoint_goal < num_waypoints ?
               waypoints[pBot.waypoint_goal].origin.x : 0.0f,
            pBot.waypoint_goal >= 0 && pBot.waypoint_goal < num_waypoints ?
               waypoints[pBot.waypoint_goal].origin.y : 0.0f,
            pBot.waypoint_goal >= 0 && pBot.waypoint_goal < num_waypoints ?
               waypoints[pBot.waypoint_goal].origin.z : 0.0f);
      }
   }

   const int ammo = CrossfireTacticsGaussStrongholdAmmo(pBot);
   if (g_crossfire_gauss_stronghold_last_ammo[bot_index] > 0 && ammo == 0)
      g_crossfire_gauss_stronghold_stats.ammo_depletion_events++;
   g_crossfire_gauss_stronghold_last_ammo[bot_index] = ammo;

   float target_distance = CROSSFIRE_GAUSS_STRONGHOLD_CROSSBOW_DISTANCE;
   if (!FNullEnt(pBot.pBotEnemy))
   {
      target_distance =
         (pBot.pBotEnemy->v.origin - pBot.pEdict->v.origin).Length();
      g_crossfire_precision_last_target_time[bot_index] = gpGlobals->time;
   }
   CrossfireTacticsUpdateGaussStrongholdFallback(
      pBot, bot_index, target_distance);

   if (CrossfireTacticsUpdateGaussStrongholdResource(pBot, bot_index))
      return TRUE;

   if (g_crossfire_gauss_stronghold_stage[bot_index] ==
       CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW)
   {
      if (CrossfireTacticsGaussStrongholdWindowReached(pBot, window_goal))
      {
         CrossfireTacticsSetGaussStrongholdWindowGoal(pBot, bot_index,
            CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
            "window_reached");
         CrossfireTacticsCompleteGaussStrongholdReturn(
            pBot, bot_index, window_goal);
      }
      else
      {
         // A completed pickup owns the next leg. Do not immediately select
         // another low-health/armor resource while still beside the first.
         CrossfireTacticsSetGaussStrongholdWindowGoal(pBot, bot_index,
            CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
            "return_pending");
      }
      return TRUE;
   }

   if (g_crossfire_gauss_stronghold_next_scan[bot_index] >
       gpGlobals->time)
   {
      CrossfireTacticsSetGaussStrongholdWindowGoal(pBot, bot_index,
         g_crossfire_gauss_stronghold_stage[bot_index], "scan_throttle");
      return TRUE;
   }
   g_crossfire_gauss_stronghold_next_scan[bot_index] = gpGlobals->time +
      CROSSFIRE_GAUSS_STRONGHOLD_AMMO_SCAN_INTERVAL;

   if (CrossfireTacticsHasImmediateDanger(pBot))
   {
      const int cover_goal =
         CrossfireTacticsFindGaussStrongholdInteriorWaypoint(pBot);
      if (cover_goal >= 0)
      {
         pBot.wpt_goal_type = WPT_GOAL_GAUSS_HOLD;
         pBot.waypoint_goal = cover_goal;
         pBot.f_waypoint_goal_time = gpGlobals->time + 1.0f;
         CrossfireTacticsSetGaussStrongholdStage(pBot, bot_index,
            CROSSFIRE_GAUSS_STRONGHOLD_LOCAL_COVER,
            "immediate_local_danger");
         return TRUE;
      }
   }

   if (pBot.pEdict->v.health <=
          CROSSFIRE_GAUSS_STRONGHOLD_HEALTH_CRITICAL &&
       CrossfireTacticsSelectGaussStrongholdResource(pBot, bot_index,
          CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH,
          CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_HEALTH,
          "critical_health"))
      return TRUE;

   if (ammo <= CROSSFIRE_GAUSS_STRONGHOLD_AMMO_LOW &&
       (CrossfireTacticsSelectGaussStrongholdResource(pBot, bot_index,
          CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_AMMO,
          CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_GAUSS,
          ammo <= CROSSFIRE_GAUSS_STRONGHOLD_AMMO_CRITICAL ?
             "critical_uranium" : "low_uranium") ||
        CrossfireTacticsSelectGaussStrongholdResource(pBot, bot_index,
          CROSSFIRE_STRONGHOLD_RESOURCE_GAUSS_REPICK,
          CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_GAUSS,
          "gauss_repickup")))
      return TRUE;

   if (pBot.pEdict->v.armorvalue <
          CROSSFIRE_GAUSS_STRONGHOLD_ARMOR_LOW &&
       CrossfireTacticsSelectGaussStrongholdResource(pBot, bot_index,
          CROSSFIRE_STRONGHOLD_RESOURCE_ARMOR,
          CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_ARMOR,
          "low_armor"))
      return TRUE;

   if (pBot.pEdict->v.health < CROSSFIRE_GAUSS_STRONGHOLD_HEALTH_LOW &&
       CrossfireTacticsSelectGaussStrongholdResource(pBot, bot_index,
          CROSSFIRE_STRONGHOLD_RESOURCE_HEALTH,
          CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_HEALTH,
          "health_topping"))
      return TRUE;

   if (FNullEnt(pBot.pBotEnemy) &&
       g_crossfire_precision_last_target_time[bot_index] +
          CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_SCAN_TIME <= gpGlobals->time &&
       g_crossfire_gauss_stronghold_next_window_change[bot_index] <=
          gpGlobals->time)
   {
      const int alternate =
         CrossfireTacticsFindGaussStrongholdWindowWaypoint(
            pBot, window_goal);
      g_crossfire_gauss_stronghold_next_window_change[bot_index] =
         gpGlobals->time + CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_SCAN_TIME;
      g_crossfire_precision_last_target_time[bot_index] = gpGlobals->time;
      if (alternate >= 0)
      {
         window_goal = alternate;
         g_crossfire_precision_hold_goal[bot_index] = alternate;
         CrossfireTacticsSetGaussStrongholdWindowGoal(pBot, bot_index,
            CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
            "scan_alternate_window");
         return TRUE;
      }
   }

   if (ammo < BOT_GAUSS_SECONDARY_MIN_AMMO)
   {
      const int preferred =
         g_crossfire_gauss_stronghold_fallback_weapon[bot_index];
      if (preferred == 0)
      {
         const int first_type = target_distance >=
            CROSSFIRE_GAUSS_STRONGHOLD_CROSSBOW_DISTANCE ?
               CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW :
               CROSSFIRE_STRONGHOLD_RESOURCE_MP5;
         const int second_type = first_type ==
            CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW ?
               CROSSFIRE_STRONGHOLD_RESOURCE_MP5 :
               CROSSFIRE_STRONGHOLD_RESOURCE_CROSSBOW;
         if (CrossfireTacticsSelectGaussStrongholdResource(
                pBot, bot_index, first_type,
                CROSSFIRE_GAUSS_STRONGHOLD_ACQUIRE_FALLBACK,
                "fallback_required") ||
             CrossfireTacticsSelectGaussStrongholdResource(
                pBot, bot_index, second_type,
                CROSSFIRE_GAUSS_STRONGHOLD_ACQUIRE_FALLBACK,
                "alternate_fallback"))
            return TRUE;
      }

      if (g_crossfire_gauss_stronghold_fallback_weapon[bot_index] ==
             VALVE_WEAPON_MP5 &&
          CrossfireTacticsWeaponAmmo(pBot, VALVE_WEAPON_MP5, TRUE) <= 0 &&
          CrossfireTacticsSelectGaussStrongholdResource(pBot, bot_index,
             CROSSFIRE_STRONGHOLD_RESOURCE_MP5_GRENADES,
             CROSSFIRE_GAUSS_STRONGHOLD_ACQUIRE_FALLBACK,
             "mp5_grenade_resupply"))
         return TRUE;

      CrossfireTacticsSetGaussStrongholdWindowGoal(pBot, bot_index,
         CROSSFIRE_GAUSS_STRONGHOLD_WAIT_RESPAWN,
         "gauss_resources_inactive");
      return TRUE;
   }

   CrossfireTacticsSetGaussStrongholdWindowGoal(pBot, bot_index,
      CrossfireTacticsGaussStrongholdWindowReached(pBot, window_goal) ?
         CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_HOLD :
         CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
      ammo >= BOT_GAUSS_SECONDARY_MIN_AMMO ?
         "gauss_ready" : "return_window");
   return TRUE;
}


static int CrossfireTacticsPrecisionHoldGoalType(int mode)
{
   return mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
      WPT_GOAL_GAUSS_HOLD : WPT_GOAL_CROSSBOW_HOLD;
}


static void CrossfireTacticsClearPrecisionHold(
   int bot_index, const char *reason)
{
   if (bot_index < 0 || bot_index >= 32)
      return;

   bot_t &bot = bots[bot_index];
   CrossfireTacticsClearGaussStronghold(bot_index, reason);
   const int mode = g_crossfire_precision_hold_mode[bot_index];
   const int goal = g_crossfire_precision_hold_goal[bot_index];
   const qboolean had_hold = mode != CROSSFIRE_PRECISION_HOLD_NONE &&
      goal >= 0;

   if (bot.wpt_goal_type == WPT_GOAL_CROSSBOW_HOLD ||
       bot.wpt_goal_type == WPT_GOAL_GAUSS_HOLD)
   {
      bot.wpt_goal_type = WPT_GOAL_NONE;
      bot.waypoint_goal = -1;
      bot.f_waypoint_goal_time = 0.0f;
   }

   g_crossfire_precision_hold_mode[bot_index] =
      CROSSFIRE_PRECISION_HOLD_NONE;
   g_crossfire_precision_hold_goal[bot_index] = -1;
   g_crossfire_precision_hold_until[bot_index] = 0.0f;
   g_crossfire_precision_last_target_time[bot_index] = 0.0f;
   g_crossfire_precision_stuck_since[bot_index] = 0.0f;
   g_crossfire_precision_hold_arrived[bot_index] = FALSE;

   if (reason == NULL)
      g_crossfire_precision_hold_retry_time[bot_index] = 0.0f;
   else if (had_hold)
      g_crossfire_precision_hold_retry_time[bot_index] = gpGlobals->time +
         (mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
            CROSSFIRE_GAUSS_HOLD_RETRY_DELAY :
            CROSSFIRE_CROSSBOW_HOLD_RETRY_DELAY);

   if (had_hold && reason != NULL && bot.name[0] != '\0')
   {
      if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS)
         UTIL_ConsolePrintf(
            "[jk_botti] gauss_hold_left: bot=%s waypoint=%d reason=%s",
            bot.name, goal, reason);
      else
         UTIL_ConsolePrintf("[jk_botti] %s left Crossfire crossbow hold: %s",
            bot.name, reason);
   }
}


static const char *CrossfireTacticsPrecisionHoldCancellationReason(
   const bot_t &pBot, int bot_index)
{
   const int mode = g_crossfire_precision_hold_mode[bot_index];
   if (CrossfireTacticsIsStrikeActive())
      return "strike";
   if (CrossfireTacticsIsBotStrikeActivator(pBot))
      return mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         "strike" : "strike activator";
   if (CrossfireTacticsIsGaussStrongholdPersistent(bot_index))
   {
      if (pBot.pEdict == NULL || pBot.pEdict->free ||
          pBot.pEdict->v.deadflag != DEAD_NO ||
          pBot.pEdict->v.health <= 0.0f)
         return "death";
      if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(
             g_crossfire_gauss_stronghold_window_goal[bot_index]))
         return "entire_zone_unreachable";
      return NULL;
   }
   if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS &&
       !BotIsCarryingWeapon(const_cast<bot_t &>(pBot), VALVE_WEAPON_GAUSS))
      return "weapon_lost";
   if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS &&
       !CrossfireTacticsHasUsableGauss(pBot))
      return "no_ammo";
   if (mode == CROSSFIRE_PRECISION_HOLD_CROSSBOW &&
       !CrossfireTacticsHasUsableCrossbow(pBot))
      return "no usable crossbow bolts";
   if (mode == CROSSFIRE_PRECISION_HOLD_CROSSBOW &&
       CrossfireTacticsHasUsableGauss(pBot))
      return "gauss priority";
   if (pBot.pEdict == NULL || pBot.pEdict->v.health <=
        (mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
           CROSSFIRE_GAUSS_CRITICAL_HEALTH :
           CROSSFIRE_CROSSBOW_CRITICAL_HEALTH))
      return mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         "low_health" : "low health";
   if (mode == CROSSFIRE_PRECISION_HOLD_CROSSBOW &&
       CrossfireTacticsHasCloseThreat(pBot))
      return "close threat";
   if (CrossfireTacticsHasImmediateDanger(pBot))
      return mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         "danger" : "immediate danger";
   if (g_crossfire_precision_hold_until[bot_index] <= gpGlobals->time)
   {
      if (g_crossfire_precision_hold_arrived[bot_index])
         return mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
            "window_complete" : "hold window complete";
   }

   const int goal = g_crossfire_precision_hold_goal[bot_index];
   if (goal < 0 || goal >= num_waypoints ||
       (waypoints[goal].flags & W_FL_DELETED))
      return mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         "unreachable" : "position unavailable";

   const float physical_distance =
      (waypoints[goal].origin - pBot.pEdict->v.origin).Length();
   const float arrival_distance =
      mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         CROSSFIRE_GAUSS_HOLD_ARRIVAL_DISTANCE :
         CROSSFIRE_CROSSBOW_HOLD_ARRIVAL_DISTANCE;
   if (pBot.curr_waypoint_index >= 0 &&
       pBot.curr_waypoint_index < num_waypoints &&
       physical_distance > arrival_distance &&
       WaypointDistanceFromTo(pBot.curr_waypoint_index, goal) >=
          WAYPOINT_UNREACHABLE)
      return mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         "unreachable" : "position unreachable";

   const qboolean recent_stuck = physical_distance > arrival_distance &&
       pBot.trace_last_stuck_wpt == pBot.curr_waypoint_index &&
       pBot.f_last_stuck_time > 0.0f &&
       pBot.f_last_stuck_time + CROSSFIRE_RECENT_STUCK_WINDOW >
          gpGlobals->time;
   if (recent_stuck)
   {
      if (g_crossfire_precision_stuck_since[bot_index] <= 0.0f)
         g_crossfire_precision_stuck_since[bot_index] = gpGlobals->time;
      else if (g_crossfire_precision_stuck_since[bot_index] +
               CROSSFIRE_STUCK_CONFIRM_TIME <= gpGlobals->time)
         return "stuck";
   }
   else
      g_crossfire_precision_stuck_since[bot_index] = 0.0f;

   if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS &&
       physical_distance <= arrival_distance &&
       !FNullEnt(pBot.pBotEnemy) &&
       !CrossfireTacticsGaussLaneHasSafeRecoil(pBot,
          pBot.pEdict->v.origin, pBot.pBotEnemy->v.origin))
      return "unsafe_recoil";

   return NULL;
}


static qboolean CrossfireTacticsEnsurePrecisionHoldGoal(bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0 || pBot.pEdict == NULL)
      return FALSE;

   if (g_crossfire_precision_hold_goal[bot_index] >= 0)
   {
      const int mode = g_crossfire_precision_hold_mode[bot_index];
      if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS &&
          CrossfireTacticsIsGaussStrongholdPersistent(bot_index))
         return CrossfireTacticsEnsureGaussStrongholdGoal(pBot);

      const char *reason = CrossfireTacticsPrecisionHoldCancellationReason(
         pBot, bot_index);
      if (reason != NULL)
      {
         CrossfireTacticsClearPrecisionHold(bot_index, reason);
         return FALSE;
      }

      if (g_crossfire_precision_hold_arrived[bot_index] &&
          !FNullEnt(pBot.pBotEnemy))
         g_crossfire_precision_last_target_time[bot_index] = gpGlobals->time;
      else if (g_crossfire_precision_hold_arrived[bot_index] &&
               g_crossfire_precision_last_target_time[bot_index] +
                  (mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
                     CROSSFIRE_GAUSS_NO_TARGET_TIMEOUT :
                     CROSSFIRE_CROSSBOW_NO_TARGET_TIMEOUT) <= gpGlobals->time)
      {
         CrossfireTacticsClearPrecisionHold(bot_index,
            mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
               "no_target" : "no target");
         return FALSE;
      }

      pBot.wpt_goal_type = CrossfireTacticsPrecisionHoldGoalType(mode);
      pBot.waypoint_goal = g_crossfire_precision_hold_goal[bot_index];
      pBot.f_waypoint_goal_time =
         g_crossfire_precision_hold_arrived[bot_index] ?
            g_crossfire_precision_hold_until[bot_index] :
            gpGlobals->time + 2.0f;
      pBot.pBotPickupItem = NULL;
      pBot.pTrackSoundEdict = NULL;
      pBot.f_track_sound_time = -1.0f;
      pBot.f_pause_time = 0.0f;
      return TRUE;
   }

   if (CrossfireTacticsIsStrikeActive() ||
       CrossfireTacticsIsBotStrikeActivator(pBot) ||
       g_crossfire_precision_hold_retry_time[bot_index] > gpGlobals->time ||
       pBot.pEdict->v.health <= CROSSFIRE_GAUSS_CRITICAL_HEALTH ||
       CrossfireTacticsHasImmediateDanger(pBot))
      return FALSE;

   int mode = CROSSFIRE_PRECISION_HOLD_NONE;
   int goal = -1;
   crossfire_gauss_hold_score_t gauss_score;
   memset(&gauss_score, 0, sizeof(gauss_score));

   if (CrossfireTacticsCanStartGaussHold(pBot))
   {
      mode = CROSSFIRE_PRECISION_HOLD_GAUSS;
      goal = CrossfireTacticsFindGaussHoldWaypoint(pBot, &gauss_score);
   }
   else if (CrossfireTacticsHasUsableCrossbow(pBot) &&
            !CrossfireTacticsHasCloseThreat(pBot))
   {
      mode = CROSSFIRE_PRECISION_HOLD_CROSSBOW;
      const int anchor = CrossfireTacticsFindCrossbowZoneAnchor(pBot);
      goal = CrossfireTacticsFindCrossbowHoldWaypoint(pBot, anchor);
   }

   if (goal < 0)
      return FALSE;

   g_crossfire_precision_hold_mode[bot_index] = mode;
   g_crossfire_precision_hold_goal[bot_index] = goal;
   g_crossfire_precision_hold_until[bot_index] = gpGlobals->time +
      (mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         RANDOM_FLOAT2(CROSSFIRE_GAUSS_HOLD_MIN_TIME,
            CROSSFIRE_GAUSS_HOLD_MAX_TIME) :
         RANDOM_FLOAT2(CROSSFIRE_CROSSBOW_HOLD_MIN_TIME,
            CROSSFIRE_CROSSBOW_HOLD_MAX_TIME));
   g_crossfire_precision_last_target_time[bot_index] = gpGlobals->time;
   g_crossfire_precision_stuck_since[bot_index] = 0.0f;
   g_crossfire_precision_hold_arrived[bot_index] = FALSE;

   if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS &&
       MapProfileCrossfireIsWaypointInsideGaussStronghold(goal))
   {
      g_crossfire_gauss_stronghold_stage[bot_index] =
         CROSSFIRE_GAUSS_STRONGHOLD_APPROACH;
      g_crossfire_gauss_stronghold_window_goal[bot_index] = goal;
      g_crossfire_gauss_stronghold_resource_goal[bot_index] = -1;
      g_crossfire_gauss_stronghold_resource[bot_index] = NULL;
      g_crossfire_gauss_stronghold_resource_type[bot_index] =
         CROSSFIRE_STRONGHOLD_RESOURCE_NONE;
      g_crossfire_gauss_stronghold_last_ammo[bot_index] =
         CrossfireTacticsGaussStrongholdAmmo(pBot);
      g_crossfire_gauss_stronghold_fallback_weapon[bot_index] = 0;
      g_crossfire_gauss_stronghold_next_weapon_select[bot_index] = 0.0f;
      g_crossfire_gauss_stronghold_strike_egress[bot_index] = FALSE;
      g_crossfire_gauss_stronghold_strike_window[bot_index] = -1;
      g_crossfire_gauss_stronghold_strike_bridge[bot_index] = -1;
      g_crossfire_gauss_stronghold_next_scan[bot_index] = 0.0f;
      g_crossfire_gauss_stronghold_next_summary[bot_index] = 0.0f;
      g_crossfire_gauss_stronghold_next_window_change[bot_index] = 0.0f;
      g_crossfire_gauss_stronghold_was_inside[bot_index] = FALSE;
   }

   pBot.wpt_goal_type = CrossfireTacticsPrecisionHoldGoalType(mode);
   pBot.waypoint_goal = goal;
   pBot.f_waypoint_goal_time = g_crossfire_precision_hold_until[bot_index];
   pBot.pBotPickupItem = NULL;
   pBot.pTrackSoundEdict = NULL;
   pBot.f_track_sound_time = -1.0f;
   pBot.f_pause_time = 0.0f;

   if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS)
   {
      UTIL_ConsolePrintf(
         "[jk_botti] gauss_hold_selected: bot=%s waypoint=%d origin=(%.0f %.0f %.0f) route_distance=%.0f elevation=%.0f visible_lanes=%d cover=%d recoil_safety=%d reservations=%d score=%.0f",
         pBot.name, goal, waypoints[goal].origin.x, waypoints[goal].origin.y,
         waypoints[goal].origin.z, gauss_score.route_distance,
         gauss_score.elevation, gauss_score.visible_lanes, gauss_score.cover,
         gauss_score.recoil_safe_lanes, gauss_score.reservations,
         gauss_score.score);
   }
   else
   {
      UTIL_ConsolePrintf(
         "[jk_botti] %s entered Crossfire crossbow hold at waypoint %d for %.1f seconds",
         pBot.name, goal,
         g_crossfire_precision_hold_until[bot_index] - gpGlobals->time);
   }
   return TRUE;
}


static qboolean CrossfireTacticsIsPrecisionHoldActive(const bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0 || g_crossfire_precision_hold_goal[bot_index] < 0)
      return FALSE;

   return CrossfireTacticsPrecisionHoldCancellationReason(
      pBot, bot_index) == NULL;
}


static void CrossfireTacticsClearBunkerShaftRoute(int index)
{
   if (index < 0 || index >= 32)
      return;

   bot_t &bot = bots[index];

   if (bot.wpt_goal_type == WPT_GOAL_BUNKER_SHAFT)
   {
      bot.wpt_goal_type = WPT_GOAL_NONE;
      bot.waypoint_goal = -1;
      bot.f_waypoint_goal_time = 0.0f;
   }

   g_crossfire_bunker_route[index] = CROSSFIRE_ROUTE_UNASSIGNED;
   g_crossfire_shaft_stage[index] = CROSSFIRE_SHAFT_STAGE_NONE;
   g_crossfire_shaft_goal[index] = -1;
   g_crossfire_shaft_next_progress_log[index] = 0.0f;
   g_crossfire_shaft_roof_logged[index] = FALSE;
   g_crossfire_shaft_slip_logged[index] = FALSE;
   g_crossfire_shaft_roof_arrival_time[index] = 0.0f;
   g_crossfire_shaft_roof_cover_fire_end[index] = 0.0f;
   g_crossfire_bunker_defender_logged[index] = FALSE;
   g_crossfire_force_shaft_route[index] = FALSE;
}


static void CrossfireTacticsResetBunkerShaftRoutes(void)
{
   for (int index = 0; index < 32; index++)
      CrossfireTacticsClearBunkerShaftRoute(index);

   g_crossfire_shaft_routes_active = FALSE;
}


static void CrossfireTacticsPrioritizeStrategicMovement(bot_t &pBot)
{
   // Item and sound tracking suppress normal waypoint movement.  A strike
   // objective must preempt both, otherwise only idle bots visibly evacuate.
   pBot.pBotPickupItem = NULL;
   pBot.pTrackSoundEdict = NULL;
   pBot.f_track_sound_time = -1.0f;
   pBot.f_find_item = gpGlobals->time + 0.5f;
   pBot.b_use_health_station = FALSE;
   pBot.b_use_HEV_station = FALSE;
   pBot.b_use_button = FALSE;
   pBot.f_pause_time = 0.0f;
   pBot.f_move_speed = pBot.f_max_speed;
   pBot.b_not_maxspeed = FALSE;
   pBot.f_strafe_direction = 0.0f;

   if (pBot.f_look_for_waypoint_time > gpGlobals->time)
      pBot.f_look_for_waypoint_time = gpGlobals->time;
}


static void CrossfireTacticsClearStrikeActivator(void)
{
   if (g_crossfire_strike_activator >= 0 && g_crossfire_strike_activator < 32)
   {
      bot_t &bot = bots[g_crossfire_strike_activator];

      if (bot.wpt_goal_type == WPT_GOAL_STRIKE_BUTTON)
      {
         bot.wpt_goal_type = WPT_GOAL_NONE;
         bot.waypoint_goal = -1;
         bot.f_waypoint_goal_time = 0.0f;
      }
   }

   g_crossfire_strike_activator = -1;
   g_crossfire_strike_activator_deadline = 0.0f;
   g_crossfire_trigger_touch_logged = FALSE;
}


static Vector CrossfireTacticsStrikeTriggerCenter(void)
{
   return VecBModelOrigin(g_crossfire_strike_trigger);
}


static int CrossfireTacticsFindReachableWaypointNear(
   const bot_t &pBot, const Vector &target, float max_distance)
{
   int best_index = -1;
   float best_distance = max_distance;

   for (int index = 0; index < num_waypoints; index++)
   {
      if (waypoints[index].flags & W_FL_DELETED)
         continue;

      const float distance = (waypoints[index].origin - target).Length();

      if (distance >= best_distance)
         continue;

      if (pBot.curr_waypoint_index >= 0 && pBot.curr_waypoint_index < num_waypoints &&
          WaypointDistanceFromTo(pBot.curr_waypoint_index, index) >= WAYPOINT_UNREACHABLE)
         continue;

      best_distance = distance;
      best_index = index;
   }

   return best_index;
}


static int CrossfireTacticsFindStrikeButtonWaypoint(const bot_t &pBot)
{
   if (g_crossfire_strike_trigger == NULL || g_crossfire_strike_trigger->free)
      return -1;

   const Vector approach = CrossfireTacticsStrikeTriggerCenter() + Vector(0.0f, -96.0f, 0.0f);
   return CrossfireTacticsFindReachableWaypointNear(pBot, approach, 256.0f);
}


static qboolean CrossfireTacticsEnsureStrikeButtonGoal(bot_t &pBot)
{
   if (!CrossfireTacticsIsBotStrikeActivator(pBot) || CrossfireTacticsIsStrikeActive())
      return FALSE;

   if (pBot.wpt_goal_type == WPT_GOAL_STRIKE_BUTTON &&
       pBot.waypoint_goal >= 0 && pBot.waypoint_goal < num_waypoints)
   {
      CrossfireTacticsPrioritizeStrategicMovement(pBot);
      return TRUE;
   }

   const int index = CrossfireTacticsFindStrikeButtonWaypoint(pBot);

   if (index == -1)
      return FALSE;

   pBot.wpt_goal_type = WPT_GOAL_STRIKE_BUTTON;
   pBot.waypoint_goal = index;
   CrossfireTacticsPrioritizeStrategicMovement(pBot);

   return TRUE;
}


static Vector CrossfireTacticsShaftRouteWaypointTarget(int route)
{
   if (route == CROSSFIRE_ROUTE_LEFT_SHAFT)
      return Vector(-432.0f, -1594.0f, -1276.0f);

   // The right roof has no post-ladder waypoint in the stock graph, so route
   // to the top ladder node and take over movement from there.
   return Vector(445.0f, -1509.0f, -1318.0f);
}


static Vector CrossfireTacticsShaftRoofEntry(int route)
{
   const float side = route == CROSSFIRE_ROUTE_LEFT_SHAFT ? -1.0f : 1.0f;
   return Vector(side * 432.0f, -1594.0f, -1276.0f);
}


static Vector CrossfireTacticsShaftLadder(int route, float height)
{
   if (route == CROSSFIRE_ROUTE_LEFT_SHAFT)
      return Vector(-447.0f, -1516.0f, height);

   return Vector(447.0f, -1509.0f, height);
}


static Vector CrossfireTacticsShaftRampStart(int route)
{
   if (route == CROSSFIRE_ROUTE_LEFT_SHAFT)
      return Vector(-272.0f, -1274.0f, -1660.0f);

   return Vector(374.0f, -1172.0f, -1660.0f);
}


static Vector CrossfireTacticsShaftRampTop(int route)
{
   if (route == CROSSFIRE_ROUTE_LEFT_SHAFT)
      return Vector(-442.0f, -1437.0f, -1629.0f);

   return Vector(420.0f, -1371.0f, -1660.0f);
}


static Vector CrossfireTacticsShaftLadderLanding(int route)
{
   if (route == CROSSFIRE_ROUTE_LEFT_SHAFT)
      return Vector(-439.0f, -1495.0f, -1596.0f);

   return Vector(448.0f, -1509.0f, -1582.0f);
}


static Vector CrossfireTacticsShaftOpening(int route)
{
   const float side = route == CROSSFIRE_ROUTE_LEFT_SHAFT ? -1.0f : 1.0f;
   return Vector(side * 320.0f, -1712.0f, -1276.0f);
}


static const char *CrossfireTacticsShaftName(int route)
{
   return route == CROSSFIRE_ROUTE_LEFT_SHAFT ? "left" : "right";
}


static int CrossfireTacticsShaftReservations(int route)
{
   int reservations = 0;

   for (int index = 0; index < 32; index++)
   {
      if (g_crossfire_bunker_route[index] == route)
         reservations++;
   }

   return reservations;
}


static float CrossfireTacticsDistanceToWaypoint(
   const bot_t &pBot, int waypoint_index)
{
   if (pBot.curr_waypoint_index >= 0 &&
       pBot.curr_waypoint_index < num_waypoints)
      return WaypointDistanceFromTo(
         pBot.curr_waypoint_index, waypoint_index);

   return (pBot.pEdict->v.origin - waypoints[waypoint_index].origin).Length();
}


static float CrossfireTacticsBunkerShaftRouteScore(
   const bot_t &pBot, int route)
{
   const int goal = CrossfireTacticsFindReachableWaypointNear(
      pBot, CrossfireTacticsShaftRouteWaypointTarget(route), 112.0f);

   if (goal == -1)
      return 999999.0f;

   return CrossfireTacticsDistanceToWaypoint(pBot, goal) +
      CrossfireTacticsShaftReservations(route) * 512.0f;
}


static qboolean CrossfireTacticsAssignBunkerShaftRoute(
   bot_t &pBot, int bot_index, int route)
{
   const int goal = CrossfireTacticsFindReachableWaypointNear(
      pBot, CrossfireTacticsShaftRouteWaypointTarget(route), 112.0f);

   if (goal == -1)
      return FALSE;

   g_crossfire_bunker_route[bot_index] = route;
   g_crossfire_shaft_stage[bot_index] = CROSSFIRE_SHAFT_STAGE_APPROACH;
   g_crossfire_shaft_goal[bot_index] = goal;
   g_crossfire_shaft_next_progress_log[bot_index] =
      gpGlobals->time + CROSSFIRE_SHAFT_PROGRESS_LOG_INTERVAL;
   pBot.wpt_goal_type = WPT_GOAL_BUNKER_SHAFT;
   pBot.waypoint_goal = goal;
   CrossfireTacticsPrioritizeStrategicMovement(pBot);

   UTIL_ConsolePrintf(
      "[jk_botti] %s is using the %s tower shaft for bunker ingress (route %.0f)",
      pBot.name, CrossfireTacticsShaftName(route),
      CrossfireTacticsDistanceToWaypoint(pBot, goal));

   return TRUE;
}


static qboolean CrossfireTacticsMainDoorsAreClosing(void)
{
   if (!CrossfireTacticsIsStrikeActive())
      return FALSE;

   if (g_crossfire_strike_start_time > 0.0f &&
       gpGlobals->time - g_crossfire_strike_start_time >=
          CROSSFIRE_MAIN_DOOR_PREEMPT_TIME)
      return TRUE;

   for (int index = 0; index < g_crossfire_main_door_count; index++)
   {
      const edict_t *door = g_crossfire_main_doors[index];

      if (door == NULL || door->free)
         continue;

      if (door->v.velocity.Length() >= CROSSFIRE_MAIN_DOOR_MOVEMENT_EPSILON ||
          (door->v.origin - g_crossfire_main_door_origins[index]).Length() >=
             CROSSFIRE_MAIN_DOOR_MOVEMENT_EPSILON)
         return TRUE;
   }

   return FALSE;
}


static float CrossfireTacticsTowerDoorEscapeCutoff(void)
{
   return g_crossfire_strike_start_time +
      CROSSFIRE_TOWER_DOOR_CLOSE_TIME -
      CROSSFIRE_TOWER_DOOR_ESCAPE_RESERVE;
}


static qboolean CrossfireTacticsTowerDoorsRequireEscape(void)
{
   return CrossfireTacticsIsStrikeActive() &&
      gpGlobals->time >= CrossfireTacticsTowerDoorEscapeCutoff();
}


static float CrossfireTacticsRoofCoverFireDeadline(void)
{
   if (CrossfireTacticsTowerDoorsRequireEscape())
      return 0.0f;

   const float desired_deadline =
      gpGlobals->time + CROSSFIRE_SHAFT_ROOF_COVER_FIRE_TIME;
   const float escape_cutoff = CrossfireTacticsTowerDoorEscapeCutoff();

   return desired_deadline < escape_cutoff
      ? desired_deadline
      : escape_cutoff;
}


static qboolean CrossfireTacticsForceShaftRouteIfDoorUnavailable(
   bot_t &pBot, int bot_index, int &route)
{
   if (route == CROSSFIRE_ROUTE_LEFT_SHAFT ||
       route == CROSSFIRE_ROUTE_RIGHT_SHAFT ||
       route == CROSSFIRE_ROUTE_SHAFT_LANDED ||
       pBot.pEdict == NULL || CrossfireTacticsIsBotSheltered(pBot))
      return FALSE;

   // A bot already past the entrance should continue deeper instead of
   // backtracking through the closing doorway to reach a tower.
   if (pBot.pEdict->v.origin.y <= CROSSFIRE_SHAFT_INGRESS_MAX_Y)
   {
      g_crossfire_force_shaft_route[bot_index] = FALSE;
      return FALSE;
   }

   if (!CrossfireTacticsMainDoorsAreClosing())
      return FALSE;

   if (!g_crossfire_force_shaft_route[bot_index])
   {
      g_crossfire_force_shaft_route[bot_index] = TRUE;
      UTIL_ConsolePrintf(
         "[jk_botti] %s sees the central bunker doors closing and is switching to a tower shaft",
         pBot.name);
   }

   route = CROSSFIRE_ROUTE_UNASSIGNED;

   if (pBot.wpt_goal_type == WPT_GOAL_BUNKER)
   {
      pBot.wpt_goal_type = WPT_GOAL_NONE;
      pBot.waypoint_goal = -1;
      pBot.f_waypoint_goal_time = 0.0f;
   }

   return TRUE;
}


static qboolean CrossfireTacticsEnsureBunkerShaftGoal(bot_t &pBot)
{
   if (!g_crossfire_shaft_routes_active)
      return FALSE;

   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);

   if (bot_index == -1)
      return FALSE;

   int &route = g_crossfire_bunker_route[bot_index];
   const qboolean force_shaft =
      CrossfireTacticsForceShaftRouteIfDoorUnavailable(
         pBot, bot_index, route);

   if (route == CROSSFIRE_ROUTE_UNASSIGNED)
   {
      if (!force_shaft &&
          (CrossfireTacticsIsBotSheltered(pBot) ||
          pBot.pEdict->v.origin.y <= CROSSFIRE_SHAFT_INGRESS_MAX_Y ||
          bot_index % 3 == 0))
      {
         route = CROSSFIRE_ROUTE_CENTRAL;
         return FALSE;
      }

      const float left_score = CrossfireTacticsBunkerShaftRouteScore(
         pBot, CROSSFIRE_ROUTE_LEFT_SHAFT);
      const float right_score = CrossfireTacticsBunkerShaftRouteScore(
         pBot, CROSSFIRE_ROUTE_RIGHT_SHAFT);
      const int preferred_route = left_score <= right_score
         ? CROSSFIRE_ROUTE_LEFT_SHAFT
         : CROSSFIRE_ROUTE_RIGHT_SHAFT;
      const int fallback_route = preferred_route == CROSSFIRE_ROUTE_LEFT_SHAFT
         ? CROSSFIRE_ROUTE_RIGHT_SHAFT
         : CROSSFIRE_ROUTE_LEFT_SHAFT;

      if (!CrossfireTacticsAssignBunkerShaftRoute(
             pBot, bot_index, preferred_route) &&
          !CrossfireTacticsAssignBunkerShaftRoute(
             pBot, bot_index, fallback_route))
      {
         route = CROSSFIRE_ROUTE_CENTRAL;
         g_crossfire_force_shaft_route[bot_index] = FALSE;
         return FALSE;
      }

      return TRUE;
   }

   if (route == CROSSFIRE_ROUTE_CENTRAL ||
       route == CROSSFIRE_ROUTE_SHAFT_LANDED)
      return FALSE;

   const int goal = g_crossfire_shaft_goal[bot_index];

   if (goal < 0 || goal >= num_waypoints)
   {
      route = CROSSFIRE_ROUTE_CENTRAL;
      return FALSE;
   }

   pBot.wpt_goal_type = WPT_GOAL_BUNKER_SHAFT;
   pBot.waypoint_goal = goal;
   CrossfireTacticsPrioritizeStrategicMovement(pBot);

   return TRUE;
}


static void CrossfireTacticsReset(void)
{
   CrossfireTacticsResetBunkerShaftRoutes();
   for (int index = 0; index < 32; index++)
   {
      CrossfireTacticsClearPrecisionHold(index, NULL);
      g_crossfire_gauss_stronghold_stage[index] =
         CROSSFIRE_GAUSS_STRONGHOLD_NONE;
      g_crossfire_gauss_stronghold_window_goal[index] = -1;
      g_crossfire_gauss_stronghold_resource_goal[index] = -1;
      g_crossfire_gauss_stronghold_resource[index] = NULL;
      g_crossfire_gauss_stronghold_resource_type[index] =
         CROSSFIRE_STRONGHOLD_RESOURCE_NONE;
      g_crossfire_gauss_stronghold_return_bridge[index] = -1;
      g_crossfire_gauss_stronghold_next_weapon_select[index] = 0.0f;
      g_crossfire_gauss_stronghold_strike_egress[index] = FALSE;
      g_crossfire_gauss_stronghold_strike_window[index] = -1;
      g_crossfire_gauss_stronghold_strike_bridge[index] = -1;
      g_crossfire_gauss_stronghold_strike_next_jump[index] = 0.0f;
      g_crossfire_gauss_stronghold_next_guard_trace[index] = 0.0f;
      g_crossfire_gauss_stronghold_next_window_change[index] = 0.0f;
   }

   memset(g_crossfire_gauss_stronghold_resources, 0,
      sizeof(g_crossfire_gauss_stronghold_resources));
   g_crossfire_gauss_stronghold_resource_count = 0;
   memset(&g_crossfire_gauss_stronghold_stats, 0,
      sizeof(g_crossfire_gauss_stronghold_stats));
   g_crossfire_gauss_stronghold_stats_time =
      gpGlobals != NULL ? gpGlobals->time : 0.0f;

   g_crossfire_strike_end_time = 0.0f;
   g_crossfire_strike_start_time = 0.0f;
   g_crossfire_next_bot_strike_time = 0.0f;
   g_crossfire_next_trigger_touch_time = 0.0f;
   g_crossfire_strike_activator_deadline = 0.0f;
   g_crossfire_strike_activator = -1;
   g_crossfire_strike_trigger = NULL;
   g_crossfire_trigger_touch_logged = FALSE;
   g_crossfire_main_door_count = 0;

   for (int index = 0; index < CROSSFIRE_MAX_MAIN_DOORS; index++)
   {
      g_crossfire_main_doors[index] = NULL;
      g_crossfire_main_door_origins[index] = Vector(0.0f, 0.0f, 0.0f);
   }
}


static void CrossfireTacticsOnEntitySpawn(edict_t *entity)
{
   if (!CrossfireTacticsIsCrossfire() || entity == NULL || entity->free ||
       FStringNull(entity->v.classname))
      return;

   const char *classname = STRING(entity->v.classname);

   CrossfireTacticsRegisterGaussStrongholdResource(entity);

   if (stricmp(classname, "trigger_multiple") == 0 &&
       !FStringNull(entity->v.target) &&
       stricmp(STRING(entity->v.target), "strike_mm") == 0)
      g_crossfire_strike_trigger = entity;

   if (stricmp(classname, "func_door") != 0 ||
       FStringNull(entity->v.targetname) ||
       stricmp(STRING(entity->v.targetname), "bunker_maindoor") != 0 ||
       g_crossfire_main_door_count >= CROSSFIRE_MAX_MAIN_DOORS)
      return;

   for (int index = 0; index < g_crossfire_main_door_count; index++)
   {
      if (g_crossfire_main_doors[index] == entity)
         return;
   }

   g_crossfire_main_doors[g_crossfire_main_door_count] = entity;
   g_crossfire_main_door_origins[g_crossfire_main_door_count] =
      entity->v.origin;
   g_crossfire_main_door_count++;
}


static void CrossfireTacticsUpdateGaussStrongholdStats(void)
{
   float elapsed = gpGlobals->time - g_crossfire_gauss_stronghold_stats_time;
   if (elapsed < 0.0f || elapsed > 1.0f)
      elapsed = 0.0f;
   g_crossfire_gauss_stronghold_stats_time = gpGlobals->time;

   for (int index = 0; index < 32; index++)
   {
      if (!CrossfireTacticsIsGaussStrongholdReserved(index))
         continue;

      if (!CrossfireTacticsBotAvailable(index))
      {
         CrossfireTacticsClearPrecisionHold(index, "death");
         continue;
      }

      if (!CrossfireTacticsIsGaussStrongholdPersistent(index))
         continue;

      g_crossfire_gauss_stronghold_stats.seconds_in_stronghold += elapsed;
      if (g_crossfire_gauss_stronghold_next_summary[index] >
          gpGlobals->time)
         continue;

      g_crossfire_gauss_stronghold_next_summary[index] = gpGlobals->time +
         CROSSFIRE_GAUSS_STRONGHOLD_SUMMARY_INTERVAL;
      const crossfire_gauss_stronghold_stats_t &stats =
         g_crossfire_gauss_stronghold_stats;
      BotTrace(bots[index],
         "gauss_stronghold_summary: entries=%u seconds=%.0f ammo_depletions=%u gauss_ammo=%u gauss_repicks=%u waits=%u health=%u armor=%u crossbow=%u mp5=%u returns=%u pursuits=%u exits_prevented=%u enemy_pursuits_prevented=%u unexpected_exits=%u window_jumps=%u recoil_falls=%u strike_exits=%u",
         stats.stronghold_entries, stats.seconds_in_stronghold,
         stats.ammo_depletion_events, stats.gauss_ammo_pickups,
         stats.gauss_repicks, stats.wait_respawn_entries,
         stats.health_pickups, stats.armor_pickups,
         stats.crossbow_fallbacks, stats.mp5_fallbacks,
         stats.returns_to_window, stats.attempted_enemy_pursuits,
         stats.window_exit_prevented,
         stats.enemy_pursuit_prevented, stats.unexpected_zone_exits,
         stats.window_jumps_prevented, stats.recoil_falls,
         stats.strike_exits);
   }
}


static void CrossfireTacticsStartFrame(void)
{
   if (!CrossfireTacticsIsCrossfire())
      return;

   CrossfireTacticsUpdateGaussStrongholdStats();

   if (g_crossfire_next_bot_strike_time <= 0.0f)
   {
      g_crossfire_next_bot_strike_time = gpGlobals->time +
         RANDOM_FLOAT2(CROSSFIRE_FIRST_BOT_STRIKE_MIN, CROSSFIRE_FIRST_BOT_STRIKE_MAX);
      return;
   }

   if (CrossfireTacticsIsStrikeActive())
   {
      CrossfireTacticsClearStrikeActivator();

      for (int index = 0; index < 32; index++)
      {
         CrossfireTacticsClearPrecisionHold(index, "strike");
         if (g_crossfire_bunker_route[index] != CROSSFIRE_ROUTE_UNASSIGNED &&
             !CrossfireTacticsBotAvailable(index))
            CrossfireTacticsClearBunkerShaftRoute(index);
      }

      return;
   }

   if (g_crossfire_shaft_routes_active)
      CrossfireTacticsResetBunkerShaftRoutes();

   if (CrossfireTacticsBotAvailable(g_crossfire_strike_activator) &&
       gpGlobals->time < g_crossfire_strike_activator_deadline)
      return;

   if (g_crossfire_strike_activator != -1)
   {
      CrossfireTacticsClearStrikeActivator();
      g_crossfire_next_bot_strike_time = gpGlobals->time + 10.0f;
      return;
   }

   if (gpGlobals->time < g_crossfire_next_bot_strike_time ||
       g_crossfire_strike_trigger == NULL || g_crossfire_strike_trigger->free)
      return;

   int best_index = -1;
   float best_distance = 999999.0f;

   for (int index = 0; index < 32; index++)
   {
      if (!CrossfireTacticsBotAvailable(index))
         continue;

      bot_t &bot = bots[index];
      const int goal = CrossfireTacticsFindStrikeButtonWaypoint(bot);

      if (goal == -1)
         continue;

      float distance;
      if (bot.curr_waypoint_index >= 0 && bot.curr_waypoint_index < num_waypoints)
         distance = WaypointDistanceFromTo(bot.curr_waypoint_index, goal);
      else
         distance = (bot.pEdict->v.origin - waypoints[goal].origin).Length();

      if (distance < best_distance)
      {
         best_distance = distance;
         best_index = index;
      }
   }

   if (best_index == -1)
   {
      g_crossfire_next_bot_strike_time = gpGlobals->time + 10.0f;
      return;
   }

   g_crossfire_strike_activator = best_index;
   CrossfireTacticsClearPrecisionHold(best_index, "strike activator");
   g_crossfire_strike_activator_deadline = gpGlobals->time + CROSSFIRE_ACTIVATOR_TIMEOUT;
   g_crossfire_trigger_touch_logged = FALSE;

   UTIL_ConsolePrintf("[jk_botti] %s is heading to the Crossfire strike button",
      bots[g_crossfire_strike_activator].name);
}


static void CrossfireTacticsOnAmbientSound(const char *sample, int flags)
{
   if (!CrossfireTacticsIsCrossfire() || sample == NULL ||
       stricmp(sample, "ambience/siren.wav") != 0 ||
       (flags & AMBIENT_SOUND_STOP_FLAG))
      return;

   const qboolean was_active = CrossfireTacticsIsStrikeActive();
   g_crossfire_strike_end_time = gpGlobals->time + CROSSFIRE_STRIKE_DURATION;

   if (!was_active)
   {
      g_crossfire_strike_start_time = gpGlobals->time;
      CrossfireTacticsClearStrikeActivator();
      for (int index = 0; index < 32; index++)
         CrossfireTacticsClearPrecisionHold(index, "strike");
      CrossfireTacticsResetBunkerShaftRoutes();
      g_crossfire_shaft_routes_active = TRUE;
      g_crossfire_next_bot_strike_time = g_crossfire_strike_end_time +
         RANDOM_FLOAT2(CROSSFIRE_REPEAT_BOT_STRIKE_MIN, CROSSFIRE_REPEAT_BOT_STRIKE_MAX);
      UTIL_ConsolePrintf("[jk_botti] Crossfire strike detected: bots evacuating to bunker");
   }
}


static qboolean CrossfireTacticsIsStrikeActive(void)
{
   return CrossfireTacticsIsCrossfire() &&
      g_crossfire_strike_end_time > gpGlobals->time;
}


static qboolean CrossfireTacticsIsBotSheltered(const bot_t &pBot)
{
   if (pBot.pEdict == NULL)
      return FALSE;

   const Vector &origin = pBot.pEdict->v.origin;

   return origin.x >= -360.0f && origin.x <= 260.0f &&
      origin.y >= -2640.0f && origin.y <= -2390.0f &&
      origin.z >= -1900.0f && origin.z <= -1740.0f;
}


static qboolean CrossfireTacticsIsStrategicGoal(const bot_t &pBot)
{
   return pBot.wpt_goal_type == WPT_GOAL_BUNKER ||
      pBot.wpt_goal_type == WPT_GOAL_STRIKE_BUTTON ||
      pBot.wpt_goal_type == WPT_GOAL_BUNKER_SHAFT ||
      pBot.wpt_goal_type == WPT_GOAL_CROSSBOW_HOLD ||
      pBot.wpt_goal_type == WPT_GOAL_GAUSS_HOLD;
}


static int CrossfireTacticsFindBunkerWaypoint(const bot_t &pBot)
{
   if (!CrossfireTacticsIsCrossfire() || pBot.pEdict == NULL)
      return -1;

   int best_route_index = -1;
   int best_physical_index = -1;
   float best_route_score = 999999.0f;
   float best_physical_score = 999999.0f;
   const qboolean has_route_start = pBot.curr_waypoint_index >= 0 &&
      pBot.curr_waypoint_index < num_waypoints;

   for (int index = 0; index < num_waypoints; index++)
   {
      if (!CrossfireTacticsIsBunkerGoalWaypoint(waypoints[index]))
         continue;

      const float reservation_penalty =
         CrossfireTacticsWaypointReservations(index, pBot) * 512.0f;
      const float physical_score =
         (pBot.pEdict->v.origin - waypoints[index].origin).Length() +
         reservation_penalty;
      if (physical_score < best_physical_score)
      {
         best_physical_score = physical_score;
         best_physical_index = index;
      }

      if (has_route_start)
      {
         const float route_distance = WaypointDistanceFromTo(
            pBot.curr_waypoint_index, index);
         const float route_score = route_distance + reservation_penalty;
         if (route_distance < WAYPOINT_UNREACHABLE &&
             route_score < best_route_score)
         {
            best_route_score = route_score;
            best_route_index = index;
         }
      }
   }

   // A stale or disconnected route-matrix anchor must not cancel evacuation.
   return best_route_index >= 0 ? best_route_index : best_physical_index;
}


static qboolean CrossfireTacticsEnsureBunkerGoal(bot_t &pBot)
{
   if (!CrossfireTacticsIsStrikeActive())
      return FALSE;

   if (CrossfireTacticsEnsureBunkerShaftGoal(pBot))
      return TRUE;

   if (pBot.wpt_goal_type == WPT_GOAL_BUNKER &&
       pBot.waypoint_goal >= 0 && pBot.waypoint_goal < num_waypoints &&
       CrossfireTacticsIsBunkerGoalWaypoint(waypoints[pBot.waypoint_goal]))
   {
      CrossfireTacticsPrioritizeStrategicMovement(pBot);
      return TRUE;
   }

   const int index = CrossfireTacticsFindBunkerWaypoint(pBot);

   if (index == -1)
      return FALSE;

   pBot.wpt_goal_type = WPT_GOAL_BUNKER;
   pBot.waypoint_goal = index;
   CrossfireTacticsPrioritizeStrategicMovement(pBot);

   return TRUE;
}


static void CrossfireTacticsMovePreciselyTowardShaftTarget(
   bot_t &pBot, const Vector &target, float speed)
{
   edict_t *pEdict = pBot.pEdict;
   Vector horizontal = target - pEdict->v.origin;
   horizontal.z = 0.0f;

   if (horizontal.Length() > 1.0f)
   {
      const Vector angles = UTIL_VecToAngles(horizontal);
      pEdict->v.ideal_yaw = UTIL_WrapAngle(angles.y);
      pEdict->v.v_angle.y = pEdict->v.ideal_yaw;
   }

   pEdict->v.v_angle.x = 0.0f;
   pEdict->v.idealpitch = 0.0f;
   pEdict->v.button |= IN_FORWARD;
   pBot.f_pause_time = 0.0f;
   pBot.f_move_speed = speed;
   pBot.b_not_maxspeed = TRUE;
   pBot.f_strafe_direction = 0.0f;
   pBot.f_dont_avoid_wall_time = gpGlobals->time + 1.0f;
}


static qboolean CrossfireTacticsBotReachedShaftRoof(
   const bot_t &pBot, int route)
{
   const Vector roof_entry = CrossfireTacticsShaftRoofEntry(route);
   const Vector offset = pBot.pEdict->v.origin - roof_entry;

   return fabs(offset.x) <= 96.0f && fabs(offset.y) <= 128.0f &&
      offset.z >= -64.0f && offset.z <= 96.0f;
}


static void CrossfireTacticsLogShaftProgress(
   const bot_t &pBot, int bot_index, int route, int goal)
{
   if (gpGlobals->time < g_crossfire_shaft_next_progress_log[bot_index])
      return;

   const float remaining = CrossfireTacticsDistanceToWaypoint(pBot, goal);
   const Vector &origin = pBot.pEdict->v.origin;

   UTIL_ConsolePrintf(
      "[jk_botti] %s approaching the %s tower shaft at %.0f %.0f %.0f "
      "(waypoint %d, remaining %.0f, ladder %d, stage %d)",
      pBot.name, CrossfireTacticsShaftName(route),
      origin.x, origin.y, origin.z, pBot.curr_waypoint_index, remaining,
      pBot.b_on_ladder ? 1 : 0, g_crossfire_shaft_stage[bot_index]);

   g_crossfire_shaft_next_progress_log[bot_index] =
      gpGlobals->time + CROSSFIRE_SHAFT_PROGRESS_LOG_INTERVAL;
}


static qboolean CrossfireTacticsShouldTakeOverShaftLadder(
   const bot_t &pBot, int route, int goal)
{
   if (CrossfireTacticsDistanceToWaypoint(pBot, goal) >
       CROSSFIRE_SHAFT_LADDER_TAKEOVER_DISTANCE)
      return FALSE;

   const Vector ladder = CrossfireTacticsShaftLadder(
      route, pBot.pEdict->v.origin.z);
   const Vector horizontal = ladder - pBot.pEdict->v.origin;

   return horizontal.Make2D().Length() <=
      CROSSFIRE_SHAFT_LADDER_MAX_HORIZONTAL_DISTANCE;
}


static qboolean CrossfireTacticsHandleShaftLadderMovement(
   bot_t &pBot, int route, int &stage)
{
   edict_t *pEdict = pBot.pEdict;
   const Vector ladder = CrossfireTacticsShaftLadder(
      route, pEdict->v.origin.z);
   const Vector horizontal = ladder - pEdict->v.origin;
   const float distance = horizontal.Make2D().Length();

   if (distance > CROSSFIRE_SHAFT_LADDER_MAX_HORIZONTAL_DISTANCE)
   {
      stage = CROSSFIRE_SHAFT_STAGE_RAMP_START;
      return FALSE;
   }

   if (distance > 1.0f)
   {
      const Vector angles = UTIL_VecToAngles(horizontal);
      pEdict->v.ideal_yaw = UTIL_WrapAngle(angles.y);
      pEdict->v.v_angle.y = pEdict->v.ideal_yaw;
   }

   pBot.f_pause_time = 0.0f;
   pBot.f_strafe_direction = 0.0f;
   pBot.f_dont_avoid_wall_time = gpGlobals->time + 1.0f;
   pEdict->v.button |= IN_FORWARD;

   if (pBot.b_on_ladder || pEdict->v.movetype == MOVETYPE_FLY)
   {
      pEdict->v.v_angle.x = -60.0f;
      pEdict->v.idealpitch = -60.0f;
      pBot.f_move_speed = pBot.f_max_speed;
      pBot.b_not_maxspeed = FALSE;
      pBot.ladder_dir = LADDER_UP;
   }
   else
   {
      pEdict->v.v_angle.x = 0.0f;
      pEdict->v.idealpitch = 0.0f;
      pBot.f_move_speed = CROSSFIRE_SHAFT_LADDER_APPROACH_SPEED;
      pBot.b_not_maxspeed = TRUE;
   }

   return TRUE;
}


static qboolean CrossfireTacticsHandleShaftRampMovement(
   bot_t &pBot, int route, int &stage)
{
   if (pBot.b_on_ladder || pBot.pEdict->v.movetype == MOVETYPE_FLY)
   {
      stage = CROSSFIRE_SHAFT_STAGE_CLIMB;
      return CrossfireTacticsHandleShaftLadderMovement(
         pBot, route, stage);
   }

   Vector target;
   float speed;
   float target_distance;

   if (stage == CROSSFIRE_SHAFT_STAGE_RAMP_START)
   {
      target = CrossfireTacticsShaftRampStart(route);
      speed = CROSSFIRE_SHAFT_RAMP_START_SPEED;
      target_distance = CROSSFIRE_SHAFT_RAMP_STAGE_DISTANCE;
   }
   else if (stage == CROSSFIRE_SHAFT_STAGE_RAMP_TOP)
   {
      target = CrossfireTacticsShaftRampTop(route);
      speed = CROSSFIRE_SHAFT_RAMP_CLIMB_SPEED;
      target_distance = CROSSFIRE_SHAFT_RAMP_STAGE_DISTANCE;
   }
   else
   {
      target = CrossfireTacticsShaftLadderLanding(route);
      speed = CROSSFIRE_SHAFT_LANDING_SPEED;
      target_distance = CROSSFIRE_SHAFT_LANDING_DISTANCE;
   }

   CrossfireTacticsMovePreciselyTowardShaftTarget(
      pBot, target, speed);

   if ((pBot.pEdict->v.origin - target).Make2D().Length() > target_distance)
      return TRUE;

   if (stage == CROSSFIRE_SHAFT_STAGE_RAMP_START)
      stage = CROSSFIRE_SHAFT_STAGE_RAMP_TOP;
   else if (stage == CROSSFIRE_SHAFT_STAGE_RAMP_TOP)
      stage = CROSSFIRE_SHAFT_STAGE_LADDER_LANDING;
   else
      stage = CROSSFIRE_SHAFT_STAGE_CLIMB;

   if (stage == CROSSFIRE_SHAFT_STAGE_CLIMB)
      return CrossfireTacticsHandleShaftLadderMovement(
         pBot, route, stage);

   return TRUE;
}


static qboolean CrossfireTacticsHandleBunkerShaftMovement(bot_t &pBot)
{
   if (!CrossfireTacticsIsStrikeActive() || pBot.pEdict == NULL)
      return FALSE;

   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);

   if (bot_index == -1)
      return FALSE;

   const int route = g_crossfire_bunker_route[bot_index];

   if (route != CROSSFIRE_ROUTE_LEFT_SHAFT &&
       route != CROSSFIRE_ROUTE_RIGHT_SHAFT)
      return FALSE;

   int &stage = g_crossfire_shaft_stage[bot_index];
   edict_t *pEdict = pBot.pEdict;
   const int goal = g_crossfire_shaft_goal[bot_index];

   if (goal < 0 || goal >= num_waypoints)
      return FALSE;

   CrossfireTacticsLogShaftProgress(pBot, bot_index, route, goal);

   if (stage == CROSSFIRE_SHAFT_STAGE_APPROACH ||
       stage == CROSSFIRE_SHAFT_STAGE_RAMP_START ||
       stage == CROSSFIRE_SHAFT_STAGE_RAMP_TOP ||
       stage == CROSSFIRE_SHAFT_STAGE_LADDER_LANDING ||
       stage == CROSSFIRE_SHAFT_STAGE_CLIMB)
   {
      if (CrossfireTacticsBotReachedShaftRoof(pBot, route))
      {
         stage = CROSSFIRE_SHAFT_STAGE_CROSS_ROOF;
         g_crossfire_shaft_roof_arrival_time[bot_index] =
            gpGlobals->time;
         g_crossfire_shaft_roof_cover_fire_end[bot_index] =
            CrossfireTacticsRoofCoverFireDeadline();

         if (!g_crossfire_shaft_roof_logged[bot_index])
         {
            g_crossfire_shaft_roof_logged[bot_index] = TRUE;

            const float cover_time =
               g_crossfire_shaft_roof_cover_fire_end[bot_index] -
               gpGlobals->time;

            if (cover_time > 0.0f)
               UTIL_ConsolePrintf(
                  "[jk_botti] %s reached the %s tower roof and has %.1f seconds for cover fire",
                  pBot.name, CrossfireTacticsShaftName(route), cover_time);
            else
               UTIL_ConsolePrintf(
                  "[jk_botti] %s reached the %s tower roof and is descending before the shutters close",
                  pBot.name, CrossfireTacticsShaftName(route));
         }
      }
      else
      {
         if (stage == CROSSFIRE_SHAFT_STAGE_APPROACH &&
             CrossfireTacticsShouldTakeOverShaftLadder(pBot, route, goal))
         {
            stage = (pBot.b_on_ladder || pEdict->v.movetype == MOVETYPE_FLY)
               ? CROSSFIRE_SHAFT_STAGE_CLIMB
               : CROSSFIRE_SHAFT_STAGE_RAMP_START;
            UTIL_ConsolePrintf("[jk_botti] %s is lining up with the %s tower ramp",
               pBot.name, CrossfireTacticsShaftName(route));
         }

         if (stage == CROSSFIRE_SHAFT_STAGE_RAMP_START ||
             stage == CROSSFIRE_SHAFT_STAGE_RAMP_TOP ||
             stage == CROSSFIRE_SHAFT_STAGE_LADDER_LANDING)
            return CrossfireTacticsHandleShaftRampMovement(
               pBot, route, stage);

         if (stage == CROSSFIRE_SHAFT_STAGE_CLIMB)
            return CrossfireTacticsHandleShaftLadderMovement(
               pBot, route, stage);

         return FALSE;
      }
   }

   if (stage == CROSSFIRE_SHAFT_STAGE_CROSS_ROOF)
   {
      const Vector roof_entry = CrossfireTacticsShaftRoofEntry(route);

      if (pEdict->v.origin.z < roof_entry.z - 96.0f)
      {
         stage = CROSSFIRE_SHAFT_STAGE_RAMP_START;
         g_crossfire_shaft_roof_arrival_time[bot_index] = 0.0f;
         g_crossfire_shaft_roof_cover_fire_end[bot_index] = 0.0f;

         if (!g_crossfire_shaft_slip_logged[bot_index])
         {
            g_crossfire_shaft_slip_logged[bot_index] = TRUE;
            UTIL_ConsolePrintf(
               "[jk_botti] %s slipped from the %s tower roof and is retrying",
               pBot.name, CrossfireTacticsShaftName(route));
         }

         return CrossfireTacticsHandleShaftRampMovement(
            pBot, route, stage);
      }

      if (pBot.b_on_ladder || pEdict->v.movetype == MOVETYPE_FLY)
         pBot.ladder_dir = LADDER_UNKNOWN;

      const qboolean cover_window_active =
         !CrossfireTacticsTowerDoorsRequireEscape() &&
         g_crossfire_shaft_roof_cover_fire_end[bot_index] >
            gpGlobals->time;
      const qboolean scanning_from_roof =
         gpGlobals->time <
            g_crossfire_shaft_roof_arrival_time[bot_index] +
            CROSSFIRE_SHAFT_ROOF_SCAN_TIME;

      if (cover_window_active &&
          (pBot.pBotEnemy != NULL || scanning_from_roof))
      {
         pBot.f_pause_time = 0.0f;
         pBot.f_move_speed = 0.0f;
         pBot.f_strafe_direction = 0.0f;
         return TRUE;
      }

      // Once cover fire ends, commit to the shaft. Do not resume combat while
      // crossing the roof or dropping through the closing shutters.
      g_crossfire_shaft_roof_cover_fire_end[bot_index] = 0.0f;

      CrossfireTacticsMovePreciselyTowardShaftTarget(
         pBot, roof_entry, CROSSFIRE_SHAFT_ROOF_MOVE_SPEED);

      if ((pEdict->v.origin - roof_entry).Make2D().Length() >
          CROSSFIRE_SHAFT_ROOF_DISTANCE)
         return TRUE;

      stage = CROSSFIRE_SHAFT_STAGE_DROP;
   }

   if (stage != CROSSFIRE_SHAFT_STAGE_DROP &&
       stage != CROSSFIRE_SHAFT_STAGE_JUMP)
      return FALSE;

   if (pEdict->v.origin.z < CROSSFIRE_SHAFT_LANDED_HEIGHT)
   {
      g_crossfire_bunker_route[bot_index] = CROSSFIRE_ROUTE_SHAFT_LANDED;
      g_crossfire_shaft_stage[bot_index] = CROSSFIRE_SHAFT_STAGE_NONE;
      g_crossfire_shaft_goal[bot_index] = -1;
      g_crossfire_shaft_roof_arrival_time[bot_index] = 0.0f;
      g_crossfire_shaft_roof_cover_fire_end[bot_index] = 0.0f;
      pBot.wpt_goal_type = WPT_GOAL_NONE;
      pBot.waypoint_goal = -1;
      pBot.f_waypoint_goal_time = 0.0f;

      UTIL_ConsolePrintf("[jk_botti] %s entered the bunker through the %s tower shaft",
         pBot.name, CrossfireTacticsShaftName(route));
      return FALSE;
   }

   const Vector opening = CrossfireTacticsShaftOpening(route);
   const Vector horizontal(
      opening.x - pEdict->v.origin.x,
      opening.y - pEdict->v.origin.y,
      0.0f);

   CrossfireTacticsMovePreciselyTowardShaftTarget(
      pBot, opening, CROSSFIRE_SHAFT_DROP_MOVE_SPEED);

   if (horizontal.Length() <= CROSSFIRE_SHAFT_JUMP_DISTANCE)
   {
      if (stage == CROSSFIRE_SHAFT_STAGE_DROP)
      {
         stage = CROSSFIRE_SHAFT_STAGE_JUMP;
         UTIL_ConsolePrintf(
            "[jk_botti] %s is jumping into the %s tower shaft",
            pBot.name, CrossfireTacticsShaftName(route));
      }

      pEdict->v.button |= IN_JUMP | IN_DUCK;
   }

   return TRUE;
}


static qboolean CrossfireTacticsEnsureStrategicGoal(bot_t &pBot)
{
   if (CrossfireTacticsIsStrikeActive())
   {
      CrossfireTacticsClearPrecisionHold(
         CrossfireTacticsBotArrayIndex(pBot), "strike");
      return CrossfireTacticsEnsureBunkerGoal(pBot);
   }

   if (CrossfireTacticsEnsureStrikeButtonGoal(pBot))
      return TRUE;

   return CrossfireTacticsEnsurePrecisionHoldGoal(pBot);
}


static qboolean CrossfireTacticsIsBotStrikeActivator(const bot_t &pBot)
{
   return g_crossfire_strike_activator >= 0 &&
      &bots[g_crossfire_strike_activator] == &pBot;
}


static qboolean CrossfireTacticsHandleStrikeActivatorMovement(bot_t &pBot)
{
   if (!CrossfireTacticsIsBotStrikeActivator(pBot) ||
       CrossfireTacticsIsStrikeActive() || pBot.pEdict == NULL ||
       g_crossfire_strike_trigger == NULL || g_crossfire_strike_trigger->free)
      return FALSE;

   edict_t *pEdict = pBot.pEdict;
   const Vector to_trigger = CrossfireTacticsStrikeTriggerCenter() - pEdict->v.origin;
   const float distance = to_trigger.Length();

   if (distance > 192.0f)
      return FALSE;

   const Vector angles = UTIL_VecToAngles(to_trigger);
   pEdict->v.idealpitch = UTIL_WrapAngle(-angles.x);
   pEdict->v.ideal_yaw = UTIL_WrapAngle(angles.y);
   pBot.f_pause_time = 0.0f;
   pBot.f_move_speed = pBot.f_max_speed;
   pBot.f_strafe_direction = 0.0f;

   if (distance <= CROSSFIRE_TRIGGER_TOUCH_DISTANCE &&
       gpGlobals->time >= g_crossfire_next_trigger_touch_time)
   {
      g_crossfire_next_trigger_touch_time = gpGlobals->time + 1.0f;
      pEdict->v.button |= IN_USE;

      if (!g_crossfire_trigger_touch_logged)
      {
         g_crossfire_trigger_touch_logged = TRUE;
         UTIL_ConsolePrintf("[jk_botti] %s touched the Crossfire strike button",
            pBot.name);
      }

      MDLL_Touch(g_crossfire_strike_trigger, pEdict);
   }

   return TRUE;
}


static qboolean CrossfireTacticsShaftMovementOverridesCombat(
   const bot_t &pBot, int bot_index)
{
   if (bot_index < 0 || bot_index >= 32)
      return FALSE;

   const int route = g_crossfire_bunker_route[bot_index];
   const int stage = g_crossfire_shaft_stage[bot_index];

   if (route != CROSSFIRE_ROUTE_LEFT_SHAFT &&
       route != CROSSFIRE_ROUTE_RIGHT_SHAFT)
      return FALSE;

   if (pBot.b_on_ladder ||
       stage == CROSSFIRE_SHAFT_STAGE_RAMP_START ||
       stage == CROSSFIRE_SHAFT_STAGE_RAMP_TOP ||
       stage == CROSSFIRE_SHAFT_STAGE_LADDER_LANDING ||
       stage == CROSSFIRE_SHAFT_STAGE_CLIMB ||
       stage == CROSSFIRE_SHAFT_STAGE_DROP ||
       stage == CROSSFIRE_SHAFT_STAGE_JUMP)
      return TRUE;

   if (stage == CROSSFIRE_SHAFT_STAGE_CROSS_ROOF)
      return CrossfireTacticsTowerDoorsRequireEscape() ||
         g_crossfire_shaft_roof_cover_fire_end[bot_index] <=
            gpGlobals->time;

   if (stage != CROSSFIRE_SHAFT_STAGE_APPROACH ||
       pBot.pEdict == NULL)
      return FALSE;

   const int goal = g_crossfire_shaft_goal[bot_index];
   if (goal < 0 || goal >= num_waypoints ||
       CrossfireTacticsDistanceToWaypoint(pBot, goal) >
          CROSSFIRE_SHAFT_LADDER_TAKEOVER_DISTANCE)
      return FALSE;

   const Vector ladder = CrossfireTacticsShaftLadder(
      route, pBot.pEdict->v.origin.z);

   return (ladder - pBot.pEdict->v.origin).Make2D().Length() <=
      CROSSFIRE_SHAFT_LADDER_COMBAT_LOCK_DISTANCE;
}


static qboolean CrossfireTacticsShouldYieldToStrategicMovement(
   const bot_t &pBot)
{
   if (pBot.pEdict == NULL)
      return FALSE;

   if (CrossfireTacticsIsPrecisionHoldActive(pBot))
      return TRUE;

   if (pBot.pBotEnemy == NULL)
      return FALSE;

   const qboolean evacuating = CrossfireTacticsIsStrikeActive() &&
      !CrossfireTacticsIsBotSheltered(pBot);

   if (!evacuating && !CrossfireTacticsIsBotStrikeActivator(pBot))
      return FALSE;

   // Keep route movement authoritative for the entire evacuation. Combat aim
   // and fire remain active, but may not stop or redirect the bot's legs.
   return TRUE;
}


static qboolean CrossfireTacticsShouldSuppressCombat(const bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index >= 0 &&
       CrossfireTacticsIsGaussStrongholdPersistent(bot_index) &&
       CrossfireTacticsGaussStrongholdStationInUseRange(
          pBot, bot_index, NULL, NULL))
      return TRUE;

   if (bot_index >= 0 &&
       g_crossfire_gauss_stronghold_strike_egress[bot_index])
      return TRUE;

   if (!CrossfireTacticsIsStrikeActive() || pBot.pEdict == NULL ||
       CrossfireTacticsIsBotSheltered(pBot))
      return FALSE;

   return bot_index >= 0 &&
      CrossfireTacticsShaftMovementOverridesCombat(pBot, bot_index);
}


static qboolean CrossfireTacticsIsBunkerDefender(const bot_t &pBot)
{
   return CrossfireTacticsIsStrikeActive() &&
      CrossfireTacticsIsBotSheltered(pBot);
}


static qboolean CrossfireTacticsShouldPrioritizeCombat(const bot_t &pBot)
{
   // Every evacuating bot actively acquires visible enemies. Strategic combat
   // windows still force it back onto the bunker route after each short burst.
   return CrossfireTacticsIsStrikeActive() ||
      CrossfireTacticsIsPrecisionHoldActive(pBot);
}


static qboolean CrossfireTacticsCanNoticeCombatTarget(
   const bot_t &pBot, const edict_t *target)
{
   if (CrossfireTacticsIsPrecisionHoldActive(pBot) && target != NULL &&
       !target->free && FBitSet(target->v.flags, FL_CLIENT))
   {
      const Vector offset = target->v.origin - pBot.pEdict->v.origin;
      const float distance = offset.Length();
      const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
      const qboolean gauss_hold = bot_index >= 0 &&
         g_crossfire_precision_hold_mode[bot_index] ==
            CROSSFIRE_PRECISION_HOLD_GAUSS;

      // Hold bots scan the open combat lanes below the balcony, while normal
      // visibility tracing still prevents information through geometry.
      return distance >= (gauss_hold ? 0.0f : BOT_CROSSBOW_MIN_DISTANCE) &&
         distance <= (gauss_hold ? CROSSFIRE_GAUSS_MAX_TARGET_DISTANCE :
            CROSSFIRE_CROSSBOW_MAX_TARGET_DISTANCE) &&
         target->v.origin.y <= pBot.pEdict->v.origin.y + 128.0f;
   }

   if (!CrossfireTacticsIsBunkerDefender(pBot) || target == NULL ||
       target->free || !FBitSet(target->v.flags, FL_CLIENT))
      return FALSE;

   const Vector &origin = target->v.origin;

   // Defenders cover only the bunker approach, central entrance and tower
   // shafts. Core combat code still requires an unobstructed visibility trace.
   return origin.x >= -900.0f && origin.x <= 900.0f &&
      origin.y >= -2400.0f && origin.y <= -900.0f &&
      origin.z >= -2050.0f && origin.z <= -1050.0f;
}


static Vector CrossfireTacticsBunkerWatchTarget(const bot_t &pBot)
{
   int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0)
      bot_index = 0;

   const int watch_index =
      ((int)(gpGlobals->time / CROSSFIRE_BUNKER_WATCH_INTERVAL) +
       bot_index) % 3;

   if (watch_index == 1)
      return Vector(-300.0f, -2280.0f, -1800.0f);

   if (watch_index == 2)
      return Vector(260.0f, -2280.0f, -1800.0f);

   return Vector(0.0f, -2240.0f, -1820.0f);
}


static qboolean CrossfireTacticsHandleBunkerDefenseMovement(bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);

   if (!CrossfireTacticsIsBunkerDefender(pBot))
   {
      if (bot_index >= 0)
         g_crossfire_bunker_defender_logged[bot_index] = FALSE;

      return FALSE;
   }

   pBot.f_pause_time = 0.0f;
   pBot.f_move_speed = 0.0f;
   pBot.f_strafe_direction = 0.0f;

   if (bot_index >= 0 && !g_crossfire_bunker_defender_logged[bot_index])
   {
      g_crossfire_bunker_defender_logged[bot_index] = TRUE;
      UTIL_ConsolePrintf(
         "[jk_botti] %s reached the bunker and is defending its entrances",
         pBot.name);
   }

   // Keep combat aim authoritative. When idle, scan the three bunker ingress
   // lanes so normal FOV and visibility checks can acquire approaching enemies.
   if (pBot.pBotEnemy == NULL)
   {
      const Vector target = CrossfireTacticsBunkerWatchTarget(pBot);
      Vector direction = target - pBot.pEdict->v.origin;
      direction.z = 0.0f;

      if (direction.Length() > 1.0f)
      {
         const Vector angles = UTIL_VecToAngles(direction);
         pBot.pEdict->v.ideal_yaw = UTIL_WrapAngle(angles.y);
      }

      pBot.pEdict->v.idealpitch = 0.0f;
   }

   return TRUE;
}


static Vector CrossfireTacticsPrecisionWatchTarget(
   const bot_t &pBot, int mode)
{
   int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0)
      bot_index = 0;

   const int watch_count = mode == CROSSFIRE_PRECISION_HOLD_GAUSS ? 6 : 3;
   const int watch_index =
      ((int)(gpGlobals->time / 2.0f) + bot_index) % watch_count;
   if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS)
      return CrossfireTacticsGaussLaneTarget(watch_index);
   if (watch_index == 1)
      return Vector(-800.0f, -300.0f, -1680.0f);
   if (watch_index == 2)
      return Vector(800.0f, -300.0f, -1680.0f);

   return Vector(0.0f, -600.0f, -1720.0f);
}


static qboolean CrossfireTacticsHandleGaussStrongholdMovement(bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0 || pBot.pEdict == NULL ||
       !CrossfireTacticsIsGaussStrongholdReserved(bot_index))
      return FALSE;

   int stage = g_crossfire_gauss_stronghold_stage[bot_index];
   if (stage == CROSSFIRE_GAUSS_STRONGHOLD_APPROACH)
   {
      const int goal = g_crossfire_precision_hold_goal[bot_index];
      if (goal < 0 || goal >= num_waypoints ||
          !CrossfireTacticsIsOriginInsideGaussStronghold(
             pBot.pEdict->v.origin) ||
          !CrossfireTacticsGaussStrongholdWindowReached(pBot, goal))
         return FALSE;

      g_crossfire_precision_hold_arrived[bot_index] = TRUE;
      g_crossfire_precision_hold_until[bot_index] = 0.0f;
      g_crossfire_precision_last_target_time[bot_index] = gpGlobals->time;
      g_crossfire_gauss_stronghold_window_goal[bot_index] = goal;
      g_crossfire_gauss_stronghold_was_inside[bot_index] = TRUE;
      g_crossfire_gauss_stronghold_stats.stronghold_entries++;
      CrossfireTacticsSetGaussStrongholdStage(pBot, bot_index,
         CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_HOLD, "window_arrival");
      BotTrace(pBot,
         "gauss_stronghold_entered: bot=%s zone=satellite_operations goal=%d ammo=%d health=%.0f armor=%.0f",
         pBot.name, goal, CrossfireTacticsGaussStrongholdAmmo(pBot),
         pBot.pEdict->v.health, pBot.pEdict->v.armorvalue);
      stage = CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_HOLD;
   }

   if (!CrossfireTacticsIsGaussStrongholdPersistent(bot_index))
      return FALSE;

   if (stage == CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_GAUSS ||
       stage == CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_HEALTH ||
       stage == CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_ARMOR ||
       stage == CROSSFIRE_GAUSS_STRONGHOLD_ACQUIRE_FALLBACK)
   {
      if (CrossfireTacticsDriveGaussStrongholdStationUse(
             pBot, bot_index))
         return TRUE;
      if (CrossfireTacticsFinishGaussStrongholdPickupApproach(
             pBot, bot_index))
         return TRUE;
      return FALSE;
   }

   if (stage == CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW &&
       CrossfireTacticsDriveGaussStrongholdReturn(pBot, bot_index))
      return TRUE;

   if (stage == CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW)
   {
      const int window_goal =
         g_crossfire_gauss_stronghold_window_goal[bot_index];
      if (!CrossfireTacticsGaussStrongholdWindowReached(
             pBot, window_goal))
         return FALSE;
      CrossfireTacticsCompleteGaussStrongholdReturn(
         pBot, bot_index, window_goal);
   }
   else
   {
      const int goal = pBot.waypoint_goal;
      if (!MapProfileCrossfireIsWaypointInsideGaussStronghold(goal) ||
          (pBot.pEdict->v.origin - waypoints[goal].origin).Length() >
             CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_ARRIVAL_DISTANCE)
         return FALSE;
   }

   pBot.f_pause_time = 0.0f;
   pBot.f_move_speed = 0.0f;
   pBot.f_strafe_direction = 0.0f;
   if (pBot.pBotEnemy == NULL)
   {
      const Vector target = CrossfireTacticsPrecisionWatchTarget(
         pBot, CROSSFIRE_PRECISION_HOLD_GAUSS);
      const Vector direction = target - pBot.pEdict->v.origin;
      const Vector angles = UTIL_VecToAngles(direction);
      pBot.pEdict->v.idealpitch = UTIL_WrapAngle(-angles.x);
      pBot.pEdict->v.ideal_yaw = UTIL_WrapAngle(angles.y);
   }
   return TRUE;
}


static qboolean CrossfireTacticsHandlePrecisionHoldMovement(bot_t &pBot)
{
   if (!CrossfireTacticsIsPrecisionHoldActive(pBot))
      return FALSE;

   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   const int mode = g_crossfire_precision_hold_mode[bot_index];
   if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS &&
       CrossfireTacticsIsGaussStrongholdReserved(bot_index))
      return CrossfireTacticsHandleGaussStrongholdMovement(pBot);

   const int goal = g_crossfire_precision_hold_goal[bot_index];
   const float arrival_distance =
      mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
         CROSSFIRE_GAUSS_HOLD_ARRIVAL_DISTANCE :
         CROSSFIRE_CROSSBOW_HOLD_ARRIVAL_DISTANCE;
   if (goal < 0 || goal >= num_waypoints ||
       (pBot.pEdict->v.origin - waypoints[goal].origin).Length() >
          arrival_distance)
      return FALSE;

   pBot.f_pause_time = 0.0f;
   pBot.f_move_speed = 0.0f;
   pBot.f_strafe_direction = 0.0f;

   if (!g_crossfire_precision_hold_arrived[bot_index])
   {
      g_crossfire_precision_hold_arrived[bot_index] = TRUE;
      g_crossfire_precision_hold_until[bot_index] = gpGlobals->time +
         (mode == CROSSFIRE_PRECISION_HOLD_GAUSS ?
            RANDOM_FLOAT2(CROSSFIRE_GAUSS_HOLD_MIN_TIME,
               CROSSFIRE_GAUSS_HOLD_MAX_TIME) :
            RANDOM_FLOAT2(CROSSFIRE_CROSSBOW_HOLD_MIN_TIME,
               CROSSFIRE_CROSSBOW_HOLD_MAX_TIME));
      g_crossfire_precision_last_target_time[bot_index] = gpGlobals->time;
      pBot.f_waypoint_goal_time =
         g_crossfire_precision_hold_until[bot_index];

      if (mode == CROSSFIRE_PRECISION_HOLD_GAUSS)
         UTIL_ConsolePrintf(
            "[jk_botti] gauss_hold_entered: bot=%s waypoint=%d hold_seconds=%.1f",
            pBot.name, goal,
            g_crossfire_precision_hold_until[bot_index] - gpGlobals->time);
   }

   if (pBot.pBotEnemy == NULL)
   {
      const Vector target = CrossfireTacticsPrecisionWatchTarget(pBot, mode);
      const Vector direction = target - pBot.pEdict->v.origin;
      const Vector angles = UTIL_VecToAngles(direction);
      pBot.pEdict->v.idealpitch = UTIL_WrapAngle(-angles.x);
      pBot.pEdict->v.ideal_yaw = UTIL_WrapAngle(angles.y);
   }

   return TRUE;
}


static qboolean CrossfireTacticsAllowWaypoint(
   bot_t &pBot, int waypoint_index, const char *context)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (CrossfireTacticsIsStrikeActive() || bot_index < 0 ||
       !CrossfireTacticsIsGaussStrongholdPersistent(bot_index))
      return TRUE;

   if (MapProfileCrossfireIsWaypointInsideGaussStronghold(waypoint_index))
      return TRUE;

   const qboolean bot_inside = pBot.pEdict != NULL &&
      CrossfireTacticsIsOriginInsideGaussStronghold(pBot.pEdict->v.origin);
   if (!bot_inside && pBot.wpt_goal_type == WPT_GOAL_GAUSS_HOLD &&
       context != NULL &&
       (strcmp(context, "route") == 0 ||
        strcmp(context, "initial") == 0 ||
        strcmp(context, "visibility") == 0))
      return TRUE;

   const qboolean enemy_pursuit = pBot.wpt_goal_type == WPT_GOAL_ENEMY;
   const char *reason = enemy_pursuit ? "enemy_pursuit" : "outside_zone";
   if (waypoint_index >= 0 && waypoint_index < num_waypoints)
   {
      if (waypoints[waypoint_index].origin.z <
          CROSSFIRE_SATELLITE_STRONGHOLD_MIN_Z)
         reason = "floor_drop";
      else if (waypoints[waypoint_index].flags &
               (W_FL_JUMP | W_FL_LONGJUMP))
         reason = "window";
   }

   if (g_crossfire_gauss_stronghold_next_guard_trace[bot_index] <=
       gpGlobals->time)
   {
      g_crossfire_gauss_stronghold_next_guard_trace[bot_index] =
         gpGlobals->time + 1.0f;
      g_crossfire_gauss_stronghold_stats.window_exit_prevented++;
      if (enemy_pursuit)
      {
         g_crossfire_gauss_stronghold_stats.attempted_enemy_pursuits++;
         g_crossfire_gauss_stronghold_stats.enemy_pursuit_prevented++;
      }
      const Vector origin = waypoint_index >= 0 &&
         waypoint_index < num_waypoints ? waypoints[waypoint_index].origin :
         Vector(0.0f, 0.0f, 0.0f);
      BotTrace(pBot,
         "gauss_stronghold_exit_prevented: candidate_goal=%d candidate_origin=%.0f,%.0f,%.0f reason=%s context=%s",
         waypoint_index, origin.x, origin.y, origin.z, reason,
         context != NULL ? context : "unknown");
   }
   return FALSE;
}


static void CrossfireTacticsApplyMovementSafety(bot_t &pBot)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (CrossfireTacticsIsStrikeActive() || bot_index < 0 ||
       pBot.pEdict == NULL ||
       !CrossfireTacticsIsGaussStrongholdPersistent(bot_index) ||
       !CrossfireTacticsIsOriginInsideGaussStronghold(
          pBot.pEdict->v.origin))
      return;

   const qboolean jump_requested =
      FBitSet(pBot.pEdict->v.button, IN_JUMP) ||
      pBot.b_longjump_do_jump || pBot.b_combat_longjump;
   if (jump_requested)
   {
      pBot.pEdict->v.button &= ~IN_JUMP;
      pBot.b_longjump_do_jump = FALSE;
      pBot.b_combat_longjump = FALSE;
      pBot.f_longjump_time = 0.0f;
      g_crossfire_gauss_stronghold_stats.window_jumps_prevented++;
   }

   if (fabs(pBot.f_move_speed) < 1.0f &&
       fabs(pBot.f_strafe_direction) < 1.0f)
      return;

   const float yaw = deg2rad(pBot.pEdict->v.v_angle.y);
   const Vector forward((float)cos(yaw), (float)sin(yaw), 0.0f);
   const Vector right(forward.y, -forward.x, 0.0f);
   float strafe_speed = 0.0f;
   if (pBot.f_move_speed != 0.0f)
   {
      strafe_speed = pBot.f_strafe_direction *
         (pBot.f_move_speed <= 20.0f ?
            pBot.f_max_speed : pBot.f_move_speed);
   }
   Vector movement = forward * pBot.f_move_speed +
      right * strafe_speed;
   if (movement.Length() < 1.0f)
      return;

   const Vector projected = pBot.pEdict->v.origin +
      movement.Normalize() * 72.0f;
   const qboolean outside =
      !CrossfireTacticsIsOriginInsideGaussStronghold(projected);
   const qboolean unsupported =
      !CrossfireTacticsHasFloorBelow(pBot, projected, 96.0f);
   qboolean converging_to_safe_goal = FALSE;
   if (!outside && unsupported &&
       MapProfileCrossfireIsWaypointInsideGaussStronghold(
          pBot.waypoint_goal))
   {
      const Vector &goal = waypoints[pBot.waypoint_goal].origin;
      converging_to_safe_goal =
         (projected - goal).Length() + 8.0f <
         (pBot.pEdict->v.origin - goal).Length();
   }
   if (!outside && (!unsupported || converging_to_safe_goal))
      return;

   pBot.f_move_speed = 0.0f;
   pBot.f_strafe_direction = 0.0f;
   pBot.pEdict->v.button &= ~IN_JUMP;
   Vector turn_target(-900.0f, 760.0f, -1500.0f);
   if (MapProfileCrossfireIsWaypointInsideGaussStronghold(
          pBot.waypoint_goal))
   {
      const Vector &goal = waypoints[pBot.waypoint_goal].origin;
      if (CrossfireTacticsGaussStrongholdSegmentSafe(
             pBot, pBot.pEdict->v.origin, goal))
         turn_target = goal;
   }

   // Stop the unsafe frame, but keep turning toward a verified local goal.
   // Replacing that yaw with the generic room center can alternate forever
   // with precise return steering after the broad waypoint radius fires.
   const Vector direction = turn_target - pBot.pEdict->v.origin;
   pBot.pEdict->v.ideal_yaw = UTIL_WrapAngle(
      UTIL_VecToAngles(direction).y);

   if (g_crossfire_gauss_stronghold_next_guard_trace[bot_index] <=
       gpGlobals->time)
   {
      g_crossfire_gauss_stronghold_next_guard_trace[bot_index] =
         gpGlobals->time + 1.0f;
      g_crossfire_gauss_stronghold_stats.window_exit_prevented++;
      BotTrace(pBot,
         "gauss_stronghold_exit_prevented: candidate_goal=%d candidate_origin=%.0f,%.0f,%.0f reason=%s context=movement",
         pBot.curr_waypoint_index, projected.x, projected.y, projected.z,
         unsupported ? "window" : "outside_zone");
   }
}


static int CrossfireTacticsPreferredWeapon(
   const bot_t &pBot, float target_distance)
{
   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
   if (bot_index < 0 ||
       !CrossfireTacticsIsGaussStrongholdPersistent(bot_index))
      return 0;

   if (CrossfireTacticsGaussStrongholdAmmo(pBot) >=
          BOT_GAUSS_SECONDARY_MIN_AMMO &&
       CrossfireTacticsStrongholdWeaponUsable(pBot, VALVE_WEAPON_GAUSS))
      return VALVE_WEAPON_GAUSS;

   const int retained =
      g_crossfire_gauss_stronghold_fallback_weapon[bot_index];
   if (retained == VALVE_WEAPON_CROSSBOW &&
       target_distance >= CROSSFIRE_GAUSS_STRONGHOLD_MP5_DISTANCE &&
       CrossfireTacticsStrongholdWeaponUsable(pBot, retained))
      return retained;
   if (retained == VALVE_WEAPON_MP5 &&
       target_distance <= CROSSFIRE_GAUSS_STRONGHOLD_CROSSBOW_DISTANCE +
          CROSSFIRE_GAUSS_STRONGHOLD_FALLBACK_HYSTERESIS &&
       CrossfireTacticsStrongholdWeaponUsable(pBot, retained))
      return retained;

   if (target_distance >= CROSSFIRE_GAUSS_STRONGHOLD_CROSSBOW_DISTANCE &&
       CrossfireTacticsStrongholdWeaponUsable(
          pBot, VALVE_WEAPON_CROSSBOW))
      return VALVE_WEAPON_CROSSBOW;
   if (CrossfireTacticsStrongholdWeaponUsable(pBot, VALVE_WEAPON_MP5))
      return VALVE_WEAPON_MP5;
   if (CrossfireTacticsStrongholdWeaponUsable(
          pBot, VALVE_WEAPON_CROSSBOW))
      return VALVE_WEAPON_CROSSBOW;
   if (CrossfireTacticsStrongholdWeaponUsable(pBot, VALVE_WEAPON_GLOCK))
      return VALVE_WEAPON_GLOCK;
   return 0;
}


static qboolean CrossfireProfileHandleSpecialMovement(bot_t &pBot)
{
   if (CrossfireTacticsHandleGaussStrongholdStrikeEgress(pBot))
      return TRUE;

   if (CrossfireTacticsHandleBunkerDefenseMovement(pBot))
      return TRUE;

   if (CrossfireTacticsHandleBunkerShaftMovement(pBot))
      return TRUE;

   if (CrossfireTacticsHandleStrikeActivatorMovement(pBot))
      return TRUE;

   return CrossfireTacticsHandlePrecisionHoldMovement(pBot);
}


static const map_profile_t g_crossfire_profile =
{
   "crossfire",
   "crossfire",
   CrossfireTacticsReset,
   CrossfireTacticsOnEntitySpawn,
   CrossfireTacticsStartFrame,
   CrossfireTacticsOnAmbientSound,
   CrossfireTacticsIsStrikeActive,
   CrossfireTacticsIsBotSheltered,
   CrossfireTacticsIsStrategicGoal,
   CrossfireTacticsEnsureStrategicGoal,
   CrossfireProfileHandleSpecialMovement,
   CrossfireTacticsShouldYieldToStrategicMovement,
   CrossfireTacticsShouldSuppressCombat,
   CrossfireTacticsShouldPrioritizeCombat,
   CrossfireTacticsCanNoticeCombatTarget,
   CrossfireTacticsShouldPreservePickup,
   CrossfireTacticsAllowWaypoint,
   CrossfireTacticsApplyMovementSafety,
   CrossfireTacticsPreferredWeapon
};


const map_profile_t *MapProfileCrossfire(void)
{
   return &g_crossfire_profile;
}
