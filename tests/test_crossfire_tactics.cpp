//
// JK_Botti - unit tests for crossfire_tactics.cpp
//

#include <stdlib.h>
#include <math.h>
#include <string.h>

#include <extdll.h>
#include <dllapi.h>
#include <h_export.h>
#include <meta_api.h>

#include "bot.h"
#include "waypoint.h"
#include "crossfire_tactics.h"

#include "engine_mock.h"
#include "test_common.h"

extern bot_t bots[32];
extern WAYPOINT waypoints[MAX_WAYPOINTS];
extern int num_waypoints;

static float mock_route_distances[MAX_WAYPOINTS];


float WaypointDistanceFromTo(int src, int dest)
{
   (void)src;
   return mock_route_distances[dest];
}


static void setup_crossfire(void)
{
   mock_reset();
   CrossfireTacticsReset();
   gpGlobals->mapname = (string_t)(long)"crossfire";
   gpGlobals->time = 100.0f;

   for (int index = 0; index < MAX_WAYPOINTS; index++)
      mock_route_distances[index] = WAYPOINT_UNREACHABLE;
}


static int test_siren_starts_and_expires_strike(void)
{
   TEST("Crossfire siren starts a bounded strike window");

   setup_crossfire();

   CrossfireTacticsOnAmbientSound("ambience/siren.wav", (1 << 5));
   ASSERT_FALSE(CrossfireTacticsIsStrikeActive());

   CrossfireTacticsOnAmbientSound("ambience/siren.wav", 0);
   ASSERT_TRUE(CrossfireTacticsIsStrikeActive());

   gpGlobals->time = 164.99f;
   ASSERT_TRUE(CrossfireTacticsIsStrikeActive());

   gpGlobals->time = 165.0f;
   ASSERT_FALSE(CrossfireTacticsIsStrikeActive());

   PASS();
   return 0;
}


static int test_other_maps_and_sounds_are_ignored(void)
{
   TEST("Only the Crossfire strike siren activates evacuation");

   setup_crossfire();
   CrossfireTacticsOnAmbientSound("ambience/wind2.wav", 0);
   ASSERT_FALSE(CrossfireTacticsIsStrikeActive());

   gpGlobals->mapname = (string_t)(long)"stalkyard";
   CrossfireTacticsOnAmbientSound("ambience/siren.wav", 0);
   ASSERT_FALSE(CrossfireTacticsIsStrikeActive());

   PASS();
   return 0;
}


static int test_shelter_bounds(void)
{
   TEST("Deep Crossfire bunker coordinates are classified as shelter");

   setup_crossfire();

   bot_t bot;
   memset(&bot, 0, sizeof(bot));
   bot.pEdict = mock_alloc_edict();

   bot.pEdict->v.origin = Vector(0.0f, -2350.0f, -1820.0f);
   ASSERT_TRUE(CrossfireTacticsIsBotSheltered(bot));

   bot.pEdict->v.origin = Vector(0.0f, -1800.0f, -1724.0f);
   ASSERT_FALSE(CrossfireTacticsIsBotSheltered(bot));

   PASS();
   return 0;
}


static int test_bunker_goal_uses_reachable_nodes_and_spreads_bots(void)
{
   TEST("Bunker goal selection spreads bots over reachable shelter nodes");

   setup_crossfire();

   num_waypoints = 4;
   waypoints[0].origin = Vector(-200.0f, -2350.0f, -1820.0f);
   waypoints[1].origin = Vector(200.0f, -2400.0f, -1820.0f);
   waypoints[2].origin = Vector(800.0f, -2400.0f, -1820.0f);
   waypoints[3].origin = Vector(0.0f, 0.0f, 0.0f);
   mock_route_distances[0] = 100.0f;
   mock_route_distances[1] = 150.0f;

   bot_t bot;
   memset(&bot, 0, sizeof(bot));
   bot.pEdict = mock_alloc_edict();
   bot.curr_waypoint_index = 3;

   ASSERT_INT(CrossfireTacticsFindBunkerWaypoint(bot), 0);

   bots[1].is_used = TRUE;
   bots[1].wpt_goal_type = WPT_GOAL_BUNKER;
   bots[1].waypoint_goal = 0;
   ASSERT_INT(CrossfireTacticsFindBunkerWaypoint(bot), 1);

   PASS();
   return 0;
}


int main(void)
{
   int fail = 0;

   printf("test_CrossfireTactics:\n");
   fail |= test_siren_starts_and_expires_strike();
   fail |= test_other_maps_and_sounds_are_ignored();
   fail |= test_shelter_bounds();
   fail |= test_bunker_goal_uses_reachable_nodes_and_spreads_bots();

   printf("\n%d/%d tests passed\n", tests_passed, tests_run);

   return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
