//
// JK_Botti - unit tests for the Crossfire map profile
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
#include "map_profile.h"

#include "engine_mock.h"
#include "test_common.h"

extern bot_t bots[32];
extern WAYPOINT waypoints[MAX_WAYPOINTS];
extern int num_waypoints;

static float mock_route_distances[MAX_WAYPOINTS];
static int mock_touch_count = 0;
static edict_t *mock_touched = NULL;
static edict_t *mock_toucher = NULL;


static void mock_touch(edict_t *touched, edict_t *toucher)
{
   mock_touch_count++;
   mock_touched = touched;
   mock_toucher = toucher;
}


float WaypointDistanceFromTo(int src, int dest)
{
   (void)src;
   return mock_route_distances[dest];
}


static void setup_crossfire(void)
{
   mock_reset();
   MapProfileReset();
   gpGlobals->mapname = (string_t)(long)"crossfire";
   gpGlobals->time = 100.0f;

   for (int index = 0; index < MAX_WAYPOINTS; index++)
      mock_route_distances[index] = WAYPOINT_UNREACHABLE;

   mock_touch_count = 0;
   mock_touched = NULL;
   mock_toucher = NULL;
}


static int test_siren_starts_and_expires_strike(void)
{
   TEST("Crossfire siren starts a bounded strike window");

   setup_crossfire();

   MapProfileOnAmbientSound("ambience/siren.wav", (1 << 5));
   ASSERT_FALSE(MapProfileIsStrategicEventActive());

   MapProfileOnAmbientSound("ambience/siren.wav", 0);
   ASSERT_TRUE(MapProfileIsStrategicEventActive());

   gpGlobals->time = 164.99f;
   ASSERT_TRUE(MapProfileIsStrategicEventActive());

   gpGlobals->time = 165.0f;
   ASSERT_FALSE(MapProfileIsStrategicEventActive());

   PASS();
   return 0;
}


static int test_other_maps_and_sounds_are_ignored(void)
{
   TEST("Only the Crossfire strike siren activates evacuation");

   setup_crossfire();
   MapProfileOnAmbientSound("ambience/wind2.wav", 0);
   ASSERT_FALSE(MapProfileIsStrategicEventActive());

   gpGlobals->mapname = (string_t)(long)"stalkyard";
   MapProfileOnAmbientSound("ambience/siren.wav", 0);
   ASSERT_FALSE(MapProfileIsStrategicEventActive());
   ASSERT_STR(MapProfileGetActiveName(), "none");

   bot_t bot;
   memset(&bot, 0, sizeof(bot));
   bot.wpt_goal_type = WPT_GOAL_BUNKER;
   ASSERT_FALSE(MapProfileIsStrategicGoal(bot));

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

   bot.pEdict->v.origin = Vector(0.0f, -2520.0f, -1820.0f);
   ASSERT_TRUE(MapProfileIsBotAtStrategicDestination(bot));

   bot.pEdict->v.origin = Vector(0.0f, -2350.0f, -1820.0f);
   ASSERT_FALSE(MapProfileIsBotAtStrategicDestination(bot));

   bot.pEdict->v.origin = Vector(0.0f, -1800.0f, -1724.0f);
   ASSERT_FALSE(MapProfileIsBotAtStrategicDestination(bot));

   PASS();
   return 0;
}


static int test_sheltered_bot_defends_bunker_entrances(void)
{
   TEST("Sheltered bot prioritizes combat and holds the bunker");

   setup_crossfire();
   MapProfileOnAmbientSound("ambience/siren.wav", 0);
   gpGlobals->time = 105.0f;

   bot_t bot;
   memset(&bot, 0, sizeof(bot));
   bot.pEdict = mock_alloc_edict();
   bot.pEdict->v.origin = Vector(0.0f, -2520.0f, -1820.0f);
   bot.f_move_speed = 320.0f;
   bot.f_strafe_direction = 80.0f;

   ASSERT_TRUE(MapProfileShouldPrioritizeCombat(bot));
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bot));
   ASSERT_FLOAT(bot.f_move_speed, 0.0f);
   ASSERT_FLOAT(bot.f_strafe_direction, 0.0f);
   ASSERT_FLOAT(bot.pEdict->v.ideal_yaw, 90.0f);

   edict_t *enemy = mock_alloc_edict();
   enemy->v.flags = FL_CLIENT;
   enemy->v.origin = Vector(0.0f, -1800.0f, -1820.0f);
   ASSERT_TRUE(MapProfileCanNoticeCombatTarget(bot, enemy));

   enemy->v.origin = Vector(1200.0f, -1800.0f, -1820.0f);
   ASSERT_FALSE(MapProfileCanNoticeCombatTarget(bot, enemy));
   enemy->v.origin = Vector(0.0f, -1800.0f, -1820.0f);

   bot.pBotEnemy = enemy;
   bot.pEdict->v.ideal_yaw = 37.0f;
   bot.f_move_speed = 320.0f;

   ASSERT_TRUE(MapProfileHandleSpecialMovement(bot));
   ASSERT_FLOAT(bot.f_move_speed, 0.0f);
   ASSERT_FLOAT(bot.pEdict->v.ideal_yaw, 37.0f);

   bot.pEdict->v.origin = Vector(0.0f, -2200.0f, -1820.0f);
   ASSERT_FALSE(MapProfileShouldPrioritizeCombat(bot));
   ASSERT_FALSE(MapProfileCanNoticeCombatTarget(bot, enemy));
   bot.pBotEnemy = NULL;
   ASSERT_FALSE(MapProfileHandleSpecialMovement(bot));

   MapProfileReset();
   PASS();
   return 0;
}


static int test_bunker_goal_uses_reachable_nodes_and_spreads_bots(void)
{
   TEST("Bunker goal selection spreads bots over reachable shelter nodes");

   setup_crossfire();

   num_waypoints = 4;
   waypoints[0].origin = Vector(-200.0f, -2450.0f, -1820.0f);
   waypoints[1].origin = Vector(200.0f, -2520.0f, -1820.0f);
   waypoints[2].origin = Vector(800.0f, -2400.0f, -1820.0f);
   waypoints[3].origin = Vector(0.0f, 0.0f, 0.0f);
   mock_route_distances[0] = 100.0f;
   mock_route_distances[1] = 150.0f;

   bot_t bot;
   memset(&bot, 0, sizeof(bot));
   bot.pEdict = mock_alloc_edict();
   bot.curr_waypoint_index = 3;

   MapProfileOnAmbientSound("ambience/siren.wav", 0);
   ASSERT_STR(MapProfileGetActiveName(), "crossfire");
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bot));
   ASSERT_INT(bot.waypoint_goal, 0);
   ASSERT_TRUE(MapProfileIsStrategicGoal(bot));

   bots[1].is_used = TRUE;
   bots[1].wpt_goal_type = WPT_GOAL_BUNKER;
   bots[1].waypoint_goal = 0;
   bot.wpt_goal_type = WPT_GOAL_NONE;
   bot.waypoint_goal = -1;
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bot));
   ASSERT_INT(bot.waypoint_goal, 1);

   PASS();
   return 0;
}


static int test_bunker_goal_preserves_enemy(void)
{
   TEST("Strike assigns bunker goal without clearing the combat target");

   setup_crossfire();

   num_waypoints = 2;
   waypoints[0].origin = Vector(0.0f, -2520.0f, -1820.0f);
   waypoints[1].origin = Vector(0.0f, 0.0f, 0.0f);

   bot_t bot;
   memset(&bot, 0, sizeof(bot));
   bot.pEdict = mock_alloc_edict();
   bot.pBotEnemy = mock_alloc_edict();
   bot.pBotPickupItem = mock_alloc_edict();
   bot.pTrackSoundEdict = mock_alloc_edict();
   bot.f_look_for_waypoint_time = gpGlobals->time + 5.0f;
   bot.curr_waypoint_index = -1;
   edict_t *enemy = bot.pBotEnemy;

   MapProfileOnAmbientSound("ambience/siren.wav", 0);

   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bot));
   ASSERT_INT(bot.wpt_goal_type, WPT_GOAL_BUNKER);
   ASSERT_INT(bot.waypoint_goal, 0);
   ASSERT_PTR_EQ(bot.pBotEnemy, enemy);
   ASSERT_PTR_EQ(bot.pBotPickupItem, NULL);
   ASSERT_PTR_EQ(bot.pTrackSoundEdict, NULL);
   ASSERT_TRUE(bot.f_look_for_waypoint_time <= gpGlobals->time);

   PASS();
   return 0;
}


static int test_bot_periodically_reaches_and_touches_strike_trigger(void)
{
   TEST("Bot periodically reaches and touches the Crossfire strike trigger");

   setup_crossfire();

   edict_t *trigger = mock_alloc_edict();
   mock_set_classname(trigger, "trigger_multiple");
   trigger->v.target = (string_t)(long)"strike_mm";
   trigger->v.absmin = Vector(-8.0f, -2226.0f, -1856.0f);
   trigger->v.size = Vector(16.0f, 14.0f, 19.0f);
   MapProfileOnEntitySpawn(trigger);

   edict_t *bot_edict = mock_alloc_edict();
   bot_edict->v.health = 100.0f;
   bot_edict->v.deadflag = DEAD_NO;
   bot_edict->v.origin = Vector(0.0f, -2249.0f, -1846.5f);

   bots[0].is_used = TRUE;
   bots[0].pEdict = bot_edict;
   bots[0].curr_waypoint_index = -1;
   bots[0].waypoint_goal = -1;
   bots[0].f_max_speed = 320.0f;
   strcpy(bots[0].name, "TriggerBot");

   edict_t *far_bot_edict = mock_alloc_edict();
   far_bot_edict->v.health = 100.0f;
   far_bot_edict->v.deadflag = DEAD_NO;
   far_bot_edict->v.origin = Vector(1000.0f, 0.0f, -1846.5f);
   bots[1].is_used = TRUE;
   bots[1].pEdict = far_bot_edict;
   bots[1].curr_waypoint_index = -1;
   bots[1].waypoint_goal = -1;
   strcpy(bots[1].name, "FarBot");

   num_waypoints = 1;
   waypoints[0].origin = Vector(0.0f, -2315.0f, -1846.5f);

   MapProfileStartFrame();
   ASSERT_FALSE(MapProfileEnsureStrategicGoal(bots[0]));

   gpGlobals->time = 1000.0f;
   MapProfileStartFrame();
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[0]));
   ASSERT_FALSE(MapProfileEnsureStrategicGoal(bots[1]));
   ASSERT_INT(bots[0].wpt_goal_type, WPT_GOAL_STRIKE_BUTTON);
   ASSERT_INT(bots[0].waypoint_goal, 0);

   gpGamedllFuncs->dllapi_table->pfnTouch = mock_touch;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[0]));
   ASSERT_INT(mock_touch_count, 1);
   ASSERT_PTR_EQ(mock_touched, trigger);
   ASSERT_PTR_EQ(mock_toucher, bot_edict);
   ASSERT_TRUE(FBitSet(bot_edict->v.button, IN_USE));

   gpGlobals->time = 1125.0f;
   MapProfileStartFrame();
   ASSERT_FALSE(MapProfileEnsureStrategicGoal(bots[0]));
   ASSERT_INT(bots[0].wpt_goal_type, WPT_GOAL_NONE);
   ASSERT_INT(bots[0].waypoint_goal, -1);

   MapProfileReset();
   PASS();
   return 0;
}


static int test_bots_use_both_tower_shafts_for_bunker_ingress(void)
{
   TEST("Crossfire evacuation distributes bots across both tower shafts");

   setup_crossfire();

   num_waypoints = 4;
   waypoints[0].origin = Vector(0.0f, -2520.0f, -1820.0f);
   waypoints[1].origin = Vector(-432.0f, -1594.0f, -1276.0f);
   waypoints[2].origin = Vector(445.0f, -1509.0f, -1318.0f);
   waypoints[3].origin = Vector(0.0f, -1000.0f, -1660.0f);
   mock_route_distances[0] = 500.0f;
   mock_route_distances[1] = 200.0f;
   mock_route_distances[2] = 220.0f;

   for (int index = 1; index <= 3; index++)
   {
      bots[index].is_used = TRUE;
      bots[index].pEdict = mock_alloc_edict();
      bots[index].pEdict->v.health = 100.0f;
      bots[index].pEdict->v.deadflag = DEAD_NO;
      bots[index].pEdict->v.origin = waypoints[3].origin;
      bots[index].curr_waypoint_index = 3;
      bots[index].waypoint_goal = -1;
      bots[index].f_max_speed = 320.0f;
   }

   strcpy(bots[1].name, "LeftShaftBot");
   strcpy(bots[2].name, "RightShaftBot");
   strcpy(bots[3].name, "CentralBot");
   bots[1].pBotPickupItem = bots[2].pEdict;
   bots[1].pTrackSoundEdict = bots[2].pEdict;
   bots[1].b_use_health_station = TRUE;
   bots[1].b_use_HEV_station = TRUE;
   bots[1].b_use_button = TRUE;
   bots[1].f_move_speed = 0.0f;
   bots[1].f_strafe_direction = 1.0f;

   MapProfileOnAmbientSound("ambience/siren.wav", 0);

   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[1]));
   ASSERT_INT(bots[1].wpt_goal_type, WPT_GOAL_BUNKER_SHAFT);
   ASSERT_INT(bots[1].waypoint_goal, 1);
   ASSERT_PTR_EQ(bots[1].pBotPickupItem, NULL);
   ASSERT_PTR_EQ(bots[1].pTrackSoundEdict, NULL);
   ASSERT_FALSE(bots[1].b_use_health_station);
   ASSERT_FALSE(bots[1].b_use_HEV_station);
   ASSERT_FALSE(bots[1].b_use_button);
   ASSERT_TRUE(bots[1].f_find_item > gpGlobals->time);
   ASSERT_FLOAT(bots[1].f_move_speed, bots[1].f_max_speed);
   ASSERT_FLOAT(bots[1].f_strafe_direction, 0.0f);

   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[2]));
   ASSERT_INT(bots[2].wpt_goal_type, WPT_GOAL_BUNKER_SHAFT);
   ASSERT_INT(bots[2].waypoint_goal, 2);

   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[3]));
   ASSERT_INT(bots[3].wpt_goal_type, WPT_GOAL_BUNKER);
   ASSERT_INT(bots[3].waypoint_goal, 0);

   // Shaft bots stop only for a short firing window. Their combat yaw is not
   // overwritten by precise ladder movement, and route movement then resumes.
   bots[1].pBotEnemy = bots[2].pEdict;
   bots[1].pEdict->v.ideal_yaw = 37.0f;
   bots[1].f_move_speed = bots[1].f_max_speed;
   gpGlobals->time = 100.4f;
   ASSERT_FALSE(MapProfileShouldYieldToStrategicMovement(bots[1]));
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[1]));
   ASSERT_FLOAT(bots[1].f_move_speed, 0.0f);
   ASSERT_FLOAT(bots[1].pEdict->v.ideal_yaw, 37.0f);

   gpGlobals->time = 100.8f;
   ASSERT_TRUE(MapProfileShouldYieldToStrategicMovement(bots[1]));
   ASSERT_FALSE(MapProfileHandleSpecialMovement(bots[1]));
   bots[1].pBotEnemy = NULL;

   bots[1].curr_waypoint_index = 1;
   bots[1].pEdict->v.origin = Vector(-368.0f, -1456.0f, -1660.0f);
   bots[1].pEdict->v.button = 0;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[1]));
   ASSERT_FLOAT(bots[1].f_move_speed, 180.0f);
   ASSERT_TRUE(bots[1].pEdict->v.ideal_yaw > 0.0f);

   bots[2].curr_waypoint_index = 2;
   bots[2].pEdict->v.origin = Vector(475.0f, -1456.0f, -1660.0f);
   bots[2].pEdict->v.button = 0;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[2]));
   ASSERT_TRUE(FBitSet(bots[2].pEdict->v.button, IN_FORWARD));
   ASSERT_FLOAT(bots[2].f_move_speed, 180.0f);
   ASSERT_TRUE(bots[2].b_not_maxspeed);

   bots[2].pEdict->v.origin = Vector(374.0f, -1172.0f, -1660.0f);
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[2]));
   ASSERT_FLOAT(bots[2].f_move_speed, 180.0f);

   bots[2].pEdict->v.origin = Vector(420.0f, -1371.0f, -1660.0f);
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[2]));
   ASSERT_FLOAT(bots[2].f_move_speed, 120.0f);

   bots[2].pEdict->v.origin = Vector(448.0f, -1509.0f, -1582.0f);
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[2]));
   ASSERT_FLOAT(bots[2].f_move_speed, 80.0f);

   bots[2].pEdict->v.origin = Vector(447.0f, -1509.0f, -1500.0f);
   bots[2].pEdict->v.movetype = MOVETYPE_FLY;
   bots[2].b_on_ladder = TRUE;
   bots[2].pEdict->v.button = 0;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[2]));
   ASSERT_TRUE(FBitSet(bots[2].pEdict->v.button, IN_FORWARD));
   ASSERT_FLOAT(bots[2].pEdict->v.v_angle.x, -60.0f);

   bots[2].pEdict->v.origin = waypoints[2].origin;
   bots[2].pEdict->v.button = 0;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[2]));
   ASSERT_FALSE(FBitSet(bots[2].pEdict->v.button, IN_JUMP));
   ASSERT_FLOAT(bots[2].f_move_speed, 80.0f);

   bots[2].pEdict->v.origin = Vector(447.0f, -1509.0f, -1500.0f);
   bots[2].pEdict->v.movetype = MOVETYPE_WALK;
   bots[2].b_on_ladder = FALSE;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[2]));
   ASSERT_FLOAT(bots[2].f_move_speed, 180.0f);

   bots[1].pEdict->v.origin = waypoints[1].origin;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[1]));
   ASSERT_TRUE(bots[1].f_move_speed > 0.0f);

   bots[1].pEdict->v.origin = Vector(-320.0f, -1660.0f, -1276.0f);
   bots[1].pEdict->v.button = 0;
   ASSERT_TRUE(MapProfileHandleSpecialMovement(bots[1]));
   ASSERT_TRUE(FBitSet(bots[1].pEdict->v.button, IN_JUMP));
   ASSERT_TRUE(FBitSet(bots[1].pEdict->v.button, IN_DUCK));

   bots[1].pEdict->v.origin = Vector(-320.0f, -1712.0f, -1600.0f);
   ASSERT_FALSE(MapProfileHandleSpecialMovement(bots[1]));
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[1]));
   ASSERT_INT(bots[1].wpt_goal_type, WPT_GOAL_BUNKER);
   ASSERT_INT(bots[1].waypoint_goal, 0);

   MapProfileReset();
   PASS();
   return 0;
}


static int setup_central_door_reroute_scenario(edict_t **door)
{
   setup_crossfire();

   *door = mock_alloc_edict();
   mock_set_classname(*door, "func_door");
   (*door)->v.targetname = (string_t)(long)"bunker_maindoor";
   MapProfileOnEntitySpawn(*door);

   num_waypoints = 4;
   waypoints[0].origin = Vector(0.0f, -2520.0f, -1820.0f);
   waypoints[1].origin = Vector(-432.0f, -1594.0f, -1276.0f);
   waypoints[2].origin = Vector(445.0f, -1509.0f, -1318.0f);
   waypoints[3].origin = Vector(0.0f, -1000.0f, -1660.0f);
   mock_route_distances[0] = 500.0f;
   mock_route_distances[1] = 200.0f;
   mock_route_distances[2] = 220.0f;

   bots[3].is_used = TRUE;
   bots[3].pEdict = mock_alloc_edict();
   bots[3].pEdict->v.health = 100.0f;
   bots[3].pEdict->v.deadflag = DEAD_NO;
   bots[3].pEdict->v.origin = waypoints[3].origin;
   bots[3].curr_waypoint_index = 3;
   bots[3].waypoint_goal = -1;
   bots[3].f_max_speed = 320.0f;
   strcpy(bots[3].name, "DoorRouteBot");

   MapProfileOnAmbientSound("ambience/siren.wav", 0);
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[3]));
   ASSERT_INT(bots[3].wpt_goal_type, WPT_GOAL_BUNKER);

   return 0;
}


static int test_closing_main_door_reroutes_central_bot_to_shaft(void)
{
   TEST("Closing Crossfire main doors reroute outside bots to a tower shaft");

   edict_t *door = NULL;
   if (setup_central_door_reroute_scenario(&door) != 0)
      return 1;

   gpGlobals->time = 116.9f;
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[3]));
   ASSERT_INT(bots[3].wpt_goal_type, WPT_GOAL_BUNKER);

   // The stock map begins its door phase at 20 seconds. Preempt the route
   // three seconds earlier so a bot does not commit to a doorway it cannot use.
   gpGlobals->time = 117.0f;
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[3]));
   ASSERT_INT(bots[3].wpt_goal_type, WPT_GOAL_BUNKER_SHAFT);
   ASSERT_INT(bots[3].waypoint_goal, 1);

   // Actual brush movement also causes an immediate switch if map timing or
   // door state differs from the expected stock sequence.
   if (setup_central_door_reroute_scenario(&door) != 0)
      return 1;
   gpGlobals->time = 105.0f;
   door->v.velocity = Vector(0.0f, 0.0f, -5.0f);
   ASSERT_TRUE(MapProfileEnsureStrategicGoal(bots[3]));
   ASSERT_INT(bots[3].wpt_goal_type, WPT_GOAL_BUNKER_SHAFT);
   ASSERT_INT(bots[3].waypoint_goal, 1);

   MapProfileReset();
   PASS();
   return 0;
}


int main(void)
{
   int fail = 0;

   printf("test_MapProfileCrossfire:\n");
   fail |= test_siren_starts_and_expires_strike();
   fail |= test_other_maps_and_sounds_are_ignored();
   fail |= test_shelter_bounds();
   fail |= test_sheltered_bot_defends_bunker_entrances();
   fail |= test_bunker_goal_uses_reachable_nodes_and_spreads_bots();
   fail |= test_bunker_goal_preserves_enemy();
   fail |= test_bot_periodically_reaches_and_touches_strike_trigger();
   fail |= test_bots_use_both_tower_shafts_for_bunker_ingress();
   fail |= test_closing_main_door_reroutes_central_bot_to_shaft();

   printf("\n%d/%d tests passed\n", tests_passed, tests_run);

   return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
