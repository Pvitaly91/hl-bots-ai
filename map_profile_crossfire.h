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
   CROSSFIRE_GAUSS_RECRUIT_APPROACH_EXTERIOR,
   CROSSFIRE_GAUSS_RECRUIT_ENTER_BUILDING,
   CROSSFIRE_GAUSS_RECRUIT_CROSS_FIRST_FLOOR,
   CROSSFIRE_GAUSS_RECRUIT_CLIMB_SECOND_FLOOR,
   CROSSFIRE_GAUSS_RECRUIT_ENTER_STRONGHOLD,
   CROSSFIRE_GAUSS_RECRUIT_ACQUIRE_GAUSS,
   CROSSFIRE_GAUSS_STRONGHOLD_WINDOW_HOLD,
   CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_GAUSS,
   CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_HEALTH,
   CROSSFIRE_GAUSS_STRONGHOLD_RESUPPLY_ARMOR,
   CROSSFIRE_GAUSS_STRONGHOLD_ACQUIRE_FALLBACK,
   CROSSFIRE_GAUSS_STRONGHOLD_WAIT_RESPAWN,
   CROSSFIRE_GAUSS_STRONGHOLD_RETURN_TO_WINDOW,
   CROSSFIRE_GAUSS_STRONGHOLD_LOCAL_COVER
};

enum crossfire_satellite_recruit_state_t
{
   CROSSFIRE_SATELLITE_RECRUIT_UNEVALUATED = 0,
   CROSSFIRE_SATELLITE_RECRUIT_DECLINED,
   CROSSFIRE_SATELLITE_RECRUIT_VOLUNTEER,
   CROSSFIRE_SATELLITE_RECRUIT_ASSIGNED
};

enum crossfire_gauss_jump_link_id_t
{
   CROSSFIRE_GAUSS_JUMP_NONE_LINK = -1,
   CROSSFIRE_GAUSS_JUMP_SATELLITE = 0,
   CROSSFIRE_GAUSS_JUMP_TUNNEL_LOFT,
   CROSSFIRE_GAUSS_JUMP_LINK_COUNT
};

enum crossfire_gauss_jump_stage_t
{
   CROSSFIRE_GAUSS_JUMP_NONE = 0,
   CROSSFIRE_GAUSS_JUMP_APPROACH,
   CROSSFIRE_GAUSS_JUMP_ALIGN,
   CROSSFIRE_GAUSS_JUMP_STABILIZE,
   CROSSFIRE_GAUSS_JUMP_CHARGE,
   CROSSFIRE_GAUSS_JUMP_TAKEOFF,
   CROSSFIRE_GAUSS_JUMP_RELEASE,
   CROSSFIRE_GAUSS_JUMP_FLIGHT,
   CROSSFIRE_GAUSS_JUMP_LAND_CONFIRM,
   CROSSFIRE_GAUSS_JUMP_RECOVER,
   CROSSFIRE_GAUSS_JUMP_FAILED
};

enum crossfire_gauss_jump_destination_role_t
{
   CROSSFIRE_GAUSS_JUMP_ROLE_NONE = 0,
   CROSSFIRE_GAUSS_JUMP_ROLE_SATELLITE,
   CROSSFIRE_GAUSS_JUMP_ROLE_TUNNEL_LOFT
};

enum crossfire_tunnel_loft_stage_t
{
   CROSSFIRE_TUNNEL_LOFT_NONE = 0,
   CROSSFIRE_TUNNEL_LOFT_ACQUIRE_RESOURCES,
   CROSSFIRE_TUNNEL_LOFT_GAUSS_HOLD,
   CROSSFIRE_TUNNEL_LOFT_EGON_HOLD,
   CROSSFIRE_TUNNEL_LOFT_RESUPPLY,
   CROSSFIRE_TUNNEL_LOFT_WAIT_RESPAWN,
   CROSSFIRE_TUNNEL_LOFT_REPOSITION
};

#define CROSSFIRE_EGON_MIN_DISTANCE 96.0f
#define CROSSFIRE_EGON_MAX_DISTANCE 560.0f
#define CROSSFIRE_EGON_URANIUM_RESERVE 12

typedef struct crossfire_gauss_jump_link_s
{
   const char *name;
   int launch_waypoint;
   Vector launch_origin;
   float launch_radius;
   float launch_min_z;
   float launch_max_z;
   Vector aim_point;
   float desired_yaw;
   float desired_pitch;
   float charge_time;
   Vector landing_mins;
   Vector landing_maxs;
   float landing_floor_z;
   int min_health;
   int min_armor;
   int min_uranium;
   int max_retries;
   int destination_role;
} crossfire_gauss_jump_link_t;

typedef struct crossfire_gauss_jump_stats_s
{
   unsigned int jump_candidates;
   unsigned int jump_selections;
   unsigned int jump_attempts;
   unsigned int jump_successes;
   unsigned int jump_failures;
   unsigned int satellite_jump_successes;
   unsigned int tunnel_loft_jump_successes;
   unsigned int stairs_fallbacks;
   unsigned int overshoots;
   unsigned int undershoots;
   unsigned int wrong_floor;
   unsigned int jump_deaths;
   unsigned int recoil_falls;
   unsigned int strike_aborts;
   unsigned int egon_pickups;
   unsigned int egon_uses;
   unsigned int gauss_uses;
   unsigned int uranium_reserve_blocks;
   unsigned int reservation_conflicts;
   float total_flight_time;
} crossfire_gauss_jump_stats_t;

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

typedef struct crossfire_satellite_recruit_stats_s
{
   unsigned int eligible_events;
   unsigned int volunteer_yes;
   unsigned int volunteer_no;
   unsigned int assignments;
   unsigned int successful_arrivals;
   unsigned int failed_approaches;
   unsigned int standby_events;
   unsigned int reservation_conflicts;
   unsigned int stair_congestion;
   unsigned int unsafe_route_rejections;
   unsigned int replacement_assignments;
   unsigned int strike_preemptions;
   unsigned int first_floor_approaches;
   unsigned int exterior_approaches;
   unsigned int gauss_acquisitions;
   unsigned int enemy_pursuit_suppressions;
   unsigned int max_simultaneous_approachers;
   float total_arrival_seconds;
   unsigned int skill_eligible[3];
   unsigned int skill_volunteer_yes[3];
   unsigned int skill_volunteer_no[3];
} crossfire_satellite_recruit_stats_t;

const map_profile_t *MapProfileCrossfire(void);
qboolean MapProfileCrossfireIsGaussStrongholdActive(const bot_t &pBot);
int MapProfileCrossfireGaussStrongholdStage(const bot_t &pBot);
qboolean MapProfileCrossfireIsWaypointInsideGaussStronghold(
   int waypoint_index);
void MapProfileCrossfireGetGaussStrongholdStats(
   crossfire_gauss_stronghold_stats_t *stats);
int MapProfileCrossfireSatelliteRecruitRoll(
   int bot_index, unsigned int spawn_epoch, unsigned int map_epoch);
int MapProfileCrossfireSatelliteRecruitState(const bot_t &pBot);
int MapProfileCrossfireSatelliteRecruitOwner(void);
unsigned int MapProfileCrossfireSatelliteRecruitSpawnEpoch(
   const bot_t &pBot);
unsigned int MapProfileCrossfireSatelliteMapEpoch(void);
void MapProfileCrossfireGetSatelliteRecruitStats(
   crossfire_satellite_recruit_stats_t *stats);
int MapProfileCrossfireGaussJumpLinkCount(void);
const crossfire_gauss_jump_link_t *MapProfileCrossfireGaussJumpLink(
   int link_id);
int MapProfileCrossfireGaussJumpLink(const bot_t &pBot);
int MapProfileCrossfireGaussJumpStage(const bot_t &pBot);
qboolean MapProfileCrossfireIsTunnelLoftActive(const bot_t &pBot);
int MapProfileCrossfireTunnelLoftStage(const bot_t &pBot);
int MapProfileCrossfireTunnelLoftOwner(void);
qboolean MapProfileCrossfireIsOriginInsideTunnelLoft(
   const Vector &origin);
void MapProfileCrossfireGetGaussJumpStats(
   crossfire_gauss_jump_stats_t *stats);

#endif // MAP_PROFILE_CROSSFIRE_H
