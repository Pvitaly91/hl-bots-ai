//
// Map-specific behavior dispatch.
//

#ifndef MAP_PROFILE_H
#define MAP_PROFILE_H

#include <extdll.h>

#include "bot.h"

typedef struct
{
   const char *name;
   const char *map_name;
   void (*reset)(void);
   void (*on_entity_spawn)(edict_t *entity);
   void (*start_frame)(void);
   void (*on_ambient_sound)(const char *sample, int flags);
   qboolean (*is_strategic_event_active)(void);
   qboolean (*is_bot_at_strategic_destination)(const bot_t &pBot);
   qboolean (*is_strategic_goal)(const bot_t &pBot);
   qboolean (*ensure_strategic_goal)(bot_t &pBot);
   qboolean (*handle_special_movement)(bot_t &pBot);
   qboolean (*should_yield_to_strategic_movement)(const bot_t &pBot);
   qboolean (*should_suppress_combat)(const bot_t &pBot);
   qboolean (*should_prioritize_combat)(const bot_t &pBot);
   qboolean (*can_notice_combat_target)(const bot_t &pBot,
      const edict_t *target);
   qboolean (*should_preserve_pickup)(const bot_t &pBot,
      const edict_t *pickup);
   qboolean (*allow_waypoint)(bot_t &pBot, int waypoint_index,
      const char *context);
   void (*apply_movement_safety)(bot_t &pBot);
   int (*preferred_weapon)(const bot_t &pBot, float target_distance);
} map_profile_t;

void MapProfileReset(void);
void MapProfileOnEntitySpawn(edict_t *entity);
void MapProfileStartFrame(void);
void MapProfileOnAmbientSound(const char *sample, int flags);
qboolean MapProfileIsStrategicEventActive(void);
qboolean MapProfileIsBotAtStrategicDestination(const bot_t &pBot);
qboolean MapProfileIsStrategicGoal(const bot_t &pBot);
qboolean MapProfileEnsureStrategicGoal(bot_t &pBot);
qboolean MapProfileHandleSpecialMovement(bot_t &pBot);
qboolean MapProfileShouldYieldToStrategicMovement(const bot_t &pBot);
qboolean MapProfileShouldSuppressCombat(const bot_t &pBot);
qboolean MapProfileShouldPrioritizeCombat(const bot_t &pBot);
qboolean MapProfileCanNoticeCombatTarget(const bot_t &pBot,
   const edict_t *target);
qboolean MapProfileShouldPreservePickup(const bot_t &pBot,
   const edict_t *pickup);
qboolean MapProfileAllowWaypoint(bot_t &pBot, int waypoint_index,
   const char *context);
void MapProfileApplyMovementSafety(bot_t &pBot);
int MapProfilePreferredWeapon(const bot_t &pBot, float target_distance);
const char *MapProfileGetActiveName(void);

#endif // MAP_PROFILE_H
