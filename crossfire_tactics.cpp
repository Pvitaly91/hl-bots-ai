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
#include "crossfire_tactics.h"

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
static const float CROSSFIRE_STRATEGIC_COMBAT_RANGE = 160.0f;
static const float CROSSFIRE_STRATEGIC_COMBAT_WINDOW = 0.40f;
static const float CROSSFIRE_CLOSE_COMBAT_WINDOW = 0.70f;
static const float CROSSFIRE_SHAFT_COMBAT_WINDOW = 0.15f;
static const float CROSSFIRE_SHAFT_CLOSE_COMBAT_WINDOW = 0.35f;
static const float CROSSFIRE_ACTIVATOR_COMBAT_WINDOW = 0.0f;
static const float CROSSFIRE_ACTIVATOR_CLOSE_COMBAT_WINDOW = 0.10f;
static const float CROSSFIRE_SHAFT_LADDER_TAKEOVER_DISTANCE = 384.0f;
static const float CROSSFIRE_SHAFT_LADDER_MAX_HORIZONTAL_DISTANCE = 192.0f;
static const float CROSSFIRE_SHAFT_LADDER_APPROACH_SPEED = 80.0f;
static const float CROSSFIRE_SHAFT_ROOF_MOVE_SPEED = 120.0f;
static const float CROSSFIRE_SHAFT_DROP_MOVE_SPEED = 80.0f;
static const float CROSSFIRE_SHAFT_ROOF_DISTANCE = 56.0f;
static const float CROSSFIRE_SHAFT_JUMP_DISTANCE = 80.0f;
static const float CROSSFIRE_SHAFT_LANDED_HEIGHT = -1450.0f;
static const float CROSSFIRE_SHAFT_INGRESS_MAX_Y = -1900.0f;
static const float CROSSFIRE_SHAFT_PROGRESS_LOG_INTERVAL = 10.0f;
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
   CROSSFIRE_SHAFT_STAGE_CLIMB,
   CROSSFIRE_SHAFT_STAGE_CROSS_ROOF,
   CROSSFIRE_SHAFT_STAGE_DROP,
   CROSSFIRE_SHAFT_STAGE_JUMP
};

static float g_crossfire_strike_end_time = 0.0f;
static float g_crossfire_next_bot_strike_time = 0.0f;
static float g_crossfire_next_trigger_touch_time = 0.0f;
static float g_crossfire_strike_activator_deadline = 0.0f;
static int g_crossfire_strike_activator = -1;
static edict_t *g_crossfire_strike_trigger = NULL;
static qboolean g_crossfire_trigger_touch_logged = FALSE;
static int g_crossfire_bunker_route[32];
static int g_crossfire_shaft_stage[32];
static int g_crossfire_shaft_goal[32];
static float g_crossfire_shaft_next_progress_log[32];
static qboolean g_crossfire_shaft_routes_active = FALSE;


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


static qboolean CrossfireTacticsEnsureBunkerShaftGoal(bot_t &pBot)
{
   if (!g_crossfire_shaft_routes_active)
      return FALSE;

   const int bot_index = CrossfireTacticsBotArrayIndex(pBot);

   if (bot_index == -1)
      return FALSE;

   int &route = g_crossfire_bunker_route[bot_index];

   if (route == CROSSFIRE_ROUTE_UNASSIGNED)
   {
      if (CrossfireTacticsIsBotSheltered(pBot) ||
          pBot.pEdict->v.origin.y <= CROSSFIRE_SHAFT_INGRESS_MAX_Y ||
          bot_index % 3 == 0)
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


void CrossfireTacticsReset(void)
{
   CrossfireTacticsResetBunkerShaftRoutes();
   g_crossfire_strike_end_time = 0.0f;
   g_crossfire_next_bot_strike_time = 0.0f;
   g_crossfire_next_trigger_touch_time = 0.0f;
   g_crossfire_strike_activator_deadline = 0.0f;
   g_crossfire_strike_activator = -1;
   g_crossfire_strike_trigger = NULL;
   g_crossfire_trigger_touch_logged = FALSE;
}


void CrossfireTacticsOnEntitySpawn(edict_t *entity)
{
   if (!CrossfireTacticsIsCrossfire() || entity == NULL || entity->free ||
       FStringNull(entity->v.classname) || FStringNull(entity->v.target))
      return;

   if (stricmp(STRING(entity->v.classname), "trigger_multiple") == 0 &&
       stricmp(STRING(entity->v.target), "strike_mm") == 0)
      g_crossfire_strike_trigger = entity;
}


void CrossfireTacticsStartFrame(void)
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


void CrossfireTacticsOnAmbientSound(const char *sample, int flags)
{
   if (!CrossfireTacticsIsCrossfire() || sample == NULL ||
       stricmp(sample, "ambience/siren.wav") != 0 ||
       (flags & AMBIENT_SOUND_STOP_FLAG))
      return;

   const qboolean was_active = CrossfireTacticsIsStrikeActive();
   g_crossfire_strike_end_time = gpGlobals->time + CROSSFIRE_STRIKE_DURATION;

   if (!was_active)
   {
      CrossfireTacticsClearStrikeActivator();
      CrossfireTacticsResetBunkerShaftRoutes();
      g_crossfire_shaft_routes_active = TRUE;
      g_crossfire_next_bot_strike_time = g_crossfire_strike_end_time +
         RANDOM_FLOAT2(CROSSFIRE_REPEAT_BOT_STRIKE_MIN, CROSSFIRE_REPEAT_BOT_STRIKE_MAX);
      UTIL_ConsolePrintf("[jk_botti] Crossfire strike detected: bots evacuating to bunker");
   }
}


qboolean CrossfireTacticsIsStrikeActive(void)
{
   return CrossfireTacticsIsCrossfire() &&
      g_crossfire_strike_end_time > gpGlobals->time;
}


qboolean CrossfireTacticsIsBotSheltered(const bot_t &pBot)
{
   if (pBot.pEdict == NULL)
      return FALSE;

   const Vector &origin = pBot.pEdict->v.origin;

   return origin.x >= -360.0f && origin.x <= 260.0f &&
      origin.y >= -2640.0f && origin.y <= -2390.0f &&
      origin.z >= -1900.0f && origin.z <= -1740.0f;
}


int CrossfireTacticsFindBunkerWaypoint(const bot_t &pBot)
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


qboolean CrossfireTacticsEnsureBunkerGoal(bot_t &pBot)
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
      stage = CROSSFIRE_SHAFT_STAGE_APPROACH;
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


qboolean CrossfireTacticsHandleBunkerShaftMovement(bot_t &pBot)
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
       stage == CROSSFIRE_SHAFT_STAGE_CLIMB)
   {
      if (CrossfireTacticsBotReachedShaftRoof(pBot, route))
      {
         stage = CROSSFIRE_SHAFT_STAGE_CROSS_ROOF;
         UTIL_ConsolePrintf("[jk_botti] %s reached the %s tower roof",
            pBot.name, CrossfireTacticsShaftName(route));
      }
      else
      {
         if (stage == CROSSFIRE_SHAFT_STAGE_APPROACH &&
             CrossfireTacticsShouldTakeOverShaftLadder(pBot, route, goal))
         {
            stage = CROSSFIRE_SHAFT_STAGE_CLIMB;
            UTIL_ConsolePrintf("[jk_botti] %s is climbing the %s tower ladder",
               pBot.name, CrossfireTacticsShaftName(route));
         }

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
         stage = CROSSFIRE_SHAFT_STAGE_CLIMB;
         UTIL_ConsolePrintf(
            "[jk_botti] %s slipped from the %s tower roof and is retrying",
            pBot.name, CrossfireTacticsShaftName(route));
         return CrossfireTacticsHandleShaftLadderMovement(
            pBot, route, stage);
      }

      CrossfireTacticsMovePreciselyTowardShaftTarget(
         pBot, roof_entry, CROSSFIRE_SHAFT_ROOF_MOVE_SPEED);

      if (pBot.b_on_ladder || pEdict->v.movetype == MOVETYPE_FLY)
      {
         pEdict->v.button |= IN_JUMP;
         pBot.ladder_dir = LADDER_UNKNOWN;
      }

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


qboolean CrossfireTacticsEnsureStrategicGoal(bot_t &pBot)
{
   if (CrossfireTacticsIsStrikeActive())
      return CrossfireTacticsEnsureBunkerGoal(pBot);

   return CrossfireTacticsEnsureStrikeButtonGoal(pBot);
}


qboolean CrossfireTacticsIsBotStrikeActivator(const bot_t &pBot)
{
   return g_crossfire_strike_activator >= 0 &&
      &bots[g_crossfire_strike_activator] == &pBot;
}


qboolean CrossfireTacticsHandleStrikeActivatorMovement(bot_t &pBot)
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


qboolean CrossfireTacticsShouldYieldToStrategicMovement(const bot_t &pBot)
{
   if (pBot.pEdict == NULL || pBot.pBotEnemy == NULL)
      return FALSE;

   const qboolean evacuating = CrossfireTacticsIsStrikeActive() &&
      !CrossfireTacticsIsBotSheltered(pBot);

   if (!evacuating && !CrossfireTacticsIsBotStrikeActivator(pBot))
      return FALSE;

   int bot_index = UTIL_GetBotIndex(pBot.pEdict);
   if (bot_index < 0)
      bot_index = 0;

   const float phase = fmod(gpGlobals->time + bot_index * 0.173f, 1.0f);
   const qboolean close_enemy =
      (pBot.pBotEnemy->v.origin - pBot.pEdict->v.origin).Length() <=
         CROSSFIRE_STRATEGIC_COMBAT_RANGE;
   float combat_window;
   const int route_index = CrossfireTacticsBotArrayIndex(pBot);
   const qboolean using_shaft = route_index >= 0 &&
      (g_crossfire_bunker_route[route_index] == CROSSFIRE_ROUTE_LEFT_SHAFT ||
       g_crossfire_bunker_route[route_index] == CROSSFIRE_ROUTE_RIGHT_SHAFT);

   if (using_shaft)
      combat_window = close_enemy
         ? CROSSFIRE_SHAFT_CLOSE_COMBAT_WINDOW
         : CROSSFIRE_SHAFT_COMBAT_WINDOW;
   else if (CrossfireTacticsIsBotStrikeActivator(pBot))
      combat_window = close_enemy
         ? CROSSFIRE_ACTIVATOR_CLOSE_COMBAT_WINDOW
         : CROSSFIRE_ACTIVATOR_COMBAT_WINDOW;
   else
      combat_window = close_enemy
         ? CROSSFIRE_CLOSE_COMBAT_WINDOW
         : CROSSFIRE_STRATEGIC_COMBAT_WINDOW;

   return phase >= combat_window;
}
