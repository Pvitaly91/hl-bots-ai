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
#include "waypoint.h"
#include "util.h"
#include "map_profile_crossfire.h"

extern bot_t bots[32];
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


static void CrossfireTacticsStartFrame(void)
{
   if (!CrossfireTacticsIsCrossfire())
      return;

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
      pBot.wpt_goal_type == WPT_GOAL_BUNKER_SHAFT;
}


static int CrossfireTacticsFindBunkerWaypoint(const bot_t &pBot)
{
   if (!CrossfireTacticsIsCrossfire() || pBot.pEdict == NULL)
      return -1;

   int best_index = -1;
   float best_score = 999999.0f;

   for (int index = 0; index < num_waypoints; index++)
   {
      if (!CrossfireTacticsIsBunkerGoalWaypoint(waypoints[index]))
         continue;

      float distance;

      if (pBot.curr_waypoint_index >= 0 && pBot.curr_waypoint_index < num_waypoints)
      {
         distance = WaypointDistanceFromTo(pBot.curr_waypoint_index, index);

         if (distance >= WAYPOINT_UNREACHABLE)
            continue;
      }
      else
      {
         distance = (pBot.pEdict->v.origin - waypoints[index].origin).Length();
      }

      // Prefer a short route while spreading bots across the available shelter nodes.
      const float score = distance +
         CrossfireTacticsWaypointReservations(index, pBot) * 512.0f;

      if (score < best_score)
      {
         best_score = score;
         best_index = index;
      }
   }

   return best_index;
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
      return CrossfireTacticsEnsureBunkerGoal(pBot);

   return CrossfireTacticsEnsureStrikeButtonGoal(pBot);
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
   if (pBot.pEdict == NULL || pBot.pBotEnemy == NULL)
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
   if (!CrossfireTacticsIsStrikeActive() || pBot.pEdict == NULL ||
       CrossfireTacticsIsBotSheltered(pBot))
      return FALSE;

   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);
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
   (void)pBot;

   // Every evacuating bot actively acquires visible enemies. Strategic combat
   // windows still force it back onto the bunker route after each short burst.
   return CrossfireTacticsIsStrikeActive();
}


static qboolean CrossfireTacticsCanNoticeCombatTarget(
   const bot_t &pBot, const edict_t *target)
{
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


static qboolean CrossfireProfileHandleSpecialMovement(bot_t &pBot)
{
   if (CrossfireTacticsHandleBunkerDefenseMovement(pBot))
      return TRUE;

   if (CrossfireTacticsHandleBunkerShaftMovement(pBot))
      return TRUE;

   return CrossfireTacticsHandleStrikeActivatorMovement(pBot);
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
   CrossfireTacticsCanNoticeCombatTarget
};


const map_profile_t *MapProfileCrossfire(void)
{
   return &g_crossfire_profile;
}
