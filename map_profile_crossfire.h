//
// Crossfire map profile registration.
//

#ifndef MAP_PROFILE_CROSSFIRE_H
#define MAP_PROFILE_CROSSFIRE_H

#include "map_profile.h"

enum crossfire_gauss_stronghold_stage_t
{
   CROSSFIRE_GAUSS_STRONGHOLD_NONE = 0,
   CROSSFIRE_GAUSS_STRONGHOLD_APPROACH,
   CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_HOLD,
   CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_GAUSS,
   CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_HEALTH,
   CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_ARMOR,
   CROSSFIRE_GAUSS_STRONGHOLD_ACQUIRE_FALLBACK,
   CROSSFIRE_GAUSS_STRONGHOLD_WAIT_RESPAWN,
   CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
   CROSSFIRE_GAUSS_STRONGHOLD_LOCAL_COVER
};

typedef struct crossfire_gauss_stronghold_stats_s
{
   unsigned int stronghold_entries;
   float seconds_in_stronghold;
   unsigned int ammo_depletion_events;
   unsigned int gauss_ammo_pickups;
   unsigned int gauss_repicks;
   unsigned int wait_respawn_entries;
   unsigned int health_pickups;
   unsigned int armor_pickups;
   unsigned int crossbow_fallbacks;
   unsigned int mp5_fallbacks;
   unsigned int returns_to_window;
   unsigned int attempted_enemy_pursuits;
   unsigned int window_exit_prevented;
   unsigned int enemy_pursuit_prevented;
   unsigned int unexpected_zone_exits;
   unsigned int window_jumps_prevented;
   unsigned int recoil_falls;
   unsigned int strike_exits;
} crossfire_gauss_stronghold_stats_t;

const map_profile_t *MapProfileCrossfire(void);
qboolean MapProfileCrossfireIsGaussStrongholdActive(const bot_t &pBot);
int MapProfileCrossfireGaussStrongholdStage(const bot_t &pBot);
qboolean MapProfileCrossfireIsWaypointInsideGaussStronghold(
   int waypoint_index);
void MapProfileCrossfireGetGaussStrongholdStats(
   crossfire_gauss_stronghold_stats_t *stats);

#endif // MAP_PROFILE_CROSSFIRE_H
