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
static const float CROSSFIRE_STRATEGIC_COMBAT_WINDOW = 0.10f;
static const float CROSSFIRE_CLOSE_COMBAT_WINDOW = 0.25f;
static const float CROSSFIRE_ACTIVATOR_COMBAT_WINDOW = 0.0f;
static const float CROSSFIRE_ACTIVATOR_CLOSE_COMBAT_WINDOW = 0.10f;
static const int AMBIENT_SOUND_STOP_FLAG = (1 << 5);
static float g_crossfire_strike_end_time = 0.0f;
static float g_crossfire_next_bot_strike_time = 0.0f;
static float g_crossfire_next_trigger_touch_time = 0.0f;
static float g_crossfire_strike_activator_deadline = 0.0f;
static int g_crossfire_strike_activator = -1;
static edict_t *g_crossfire_strike_trigger = NULL;
static qboolean g_crossfire_trigger_touch_logged = FALSE;


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


static void CrossfireTacticsPrioritizeStrategicMovement(bot_t &pBot)
{
   // Item and sound tracking suppress normal waypoint movement.  A strike
   // objective must preempt both, otherwise only idle bots visibly evacuate.
   pBot.pBotPickupItem = NULL;
   pBot.pTrackSoundEdict = NULL;
   pBot.f_track_sound_time = -1.0f;
   pBot.f_pause_time = 0.0f;

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


static int CrossfireTacticsFindStrikeButtonWaypoint(const bot_t &pBot)
{
   if (g_crossfire_strike_trigger == NULL || g_crossfire_strike_trigger->free)
      return -1;

   const Vector approach = CrossfireTacticsStrikeTriggerCenter() + Vector(0.0f, -96.0f, 0.0f);
   int best_index = -1;
   float best_distance = 256.0f;

   for (int index = 0; index < num_waypoints; index++)
   {
      if (waypoints[index].flags & W_FL_DELETED)
         continue;

      const float distance = (waypoints[index].origin - approach).Length();

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


void CrossfireTacticsReset(void)
{
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
      return;
   }

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

   if (CrossfireTacticsIsBotStrikeActivator(pBot))
      combat_window = close_enemy
         ? CROSSFIRE_ACTIVATOR_CLOSE_COMBAT_WINDOW
         : CROSSFIRE_ACTIVATOR_COMBAT_WINDOW;
   else
      combat_window = close_enemy
         ? CROSSFIRE_CLOSE_COMBAT_WINDOW
         : CROSSFIRE_STRATEGIC_COMBAT_WINDOW;

   return phase >= combat_window;
}
