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
   qboolean (*should_prioritize_combat)(const bot_t &pBot);
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
qboolean MapProfileShouldPrioritizeCombat(const bot_t &pBot);
const char *MapProfileGetActiveName(void);

#endif // MAP_PROFILE_H
