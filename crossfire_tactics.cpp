//
// Crossfire-specific tactical behavior.
//

#include <string.h>

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
static const int AMBIENT_SOUND_STOP_FLAG = (1 << 5);
static float g_crossfire_strike_end_time = 0.0f;


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
      origin.x >= -400.0f && origin.x <= 400.0f &&
      origin.y >= -2600.0f && origin.y <= -2250.0f &&
      origin.z >= -1900.0f && origin.z <= -1750.0f;
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


void CrossfireTacticsReset(void)
{
   g_crossfire_strike_end_time = 0.0f;
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
      UTIL_ConsolePrintf("[jk_botti] Crossfire strike detected: bots evacuating to bunker");
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

   return origin.x >= -720.0f && origin.x <= 720.0f &&
      origin.y >= -2800.0f && origin.y <= -2220.0f &&
      origin.z >= -1920.0f && origin.z <= -1680.0f;
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
      return TRUE;

   const int index = CrossfireTacticsFindBunkerWaypoint(pBot);

   if (index == -1)
      return FALSE;

   pBot.wpt_goal_type = WPT_GOAL_BUNKER;
   pBot.waypoint_goal = index;
   pBot.pTrackSoundEdict = NULL;
   pBot.f_track_sound_time = -1.0f;

   return TRUE;
}
