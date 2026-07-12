//
// Map-specific behavior dispatch.
//

#include <string.h>

#include <extdll.h>
#include <dllapi.h>
#include <h_export.h>
#include <meta_api.h>

#include "map_profile.h"
#include "map_profile_crossfire.h"

static const map_profile_t *g_active_map_profile = NULL;
static char g_active_map_name[64];
static qboolean g_map_profile_resolved = FALSE;


static int MapProfileCount(void)
{
   return 1;
}


static const map_profile_t *MapProfileAt(int index)
{
   // Register future map profiles here; bot core call sites stay unchanged.
   if (index == 0)
      return MapProfileCrossfire();

   return NULL;
}


static const char *MapProfileCurrentMapName(void)
{
   if (gpGlobals == NULL || gpGlobals->mapname == 0)
      return "";

   return STRING(gpGlobals->mapname);
}


static const map_profile_t *MapProfileResolve(void)
{
   const char *map_name = MapProfileCurrentMapName();

   if (g_map_profile_resolved &&
       stricmp(g_active_map_name, map_name) == 0)
      return g_active_map_profile;

   if (g_active_map_profile != NULL &&
       g_active_map_profile->reset != NULL)
      g_active_map_profile->reset();

   g_active_map_profile = NULL;
   strncpy(g_active_map_name, map_name, sizeof(g_active_map_name) - 1);
   g_active_map_name[sizeof(g_active_map_name) - 1] = '\0';
   g_map_profile_resolved = TRUE;

   for (int index = 0; index < MapProfileCount(); index++)
   {
      const map_profile_t *profile = MapProfileAt(index);

      if (profile != NULL && profile->map_name != NULL &&
          stricmp(profile->map_name, map_name) == 0)
      {
         g_active_map_profile = profile;
         break;
      }
   }

   return g_active_map_profile;
}


void MapProfileReset(void)
{
   for (int index = 0; index < MapProfileCount(); index++)
   {
      const map_profile_t *profile = MapProfileAt(index);

      if (profile != NULL && profile->reset != NULL)
         profile->reset();
   }

   g_active_map_profile = NULL;
   g_active_map_name[0] = '\0';
   g_map_profile_resolved = FALSE;
}


void MapProfileOnEntitySpawn(edict_t *entity)
{
   const map_profile_t *profile = MapProfileResolve();

   if (profile != NULL && profile->on_entity_spawn != NULL)
      profile->on_entity_spawn(entity);
}


void MapProfileStartFrame(void)
{
   const map_profile_t *profile = MapProfileResolve();

   if (profile != NULL && profile->start_frame != NULL)
      profile->start_frame();
}


void MapProfileOnAmbientSound(const char *sample, int flags)
{
   const map_profile_t *profile = MapProfileResolve();

   if (profile != NULL && profile->on_ambient_sound != NULL)
      profile->on_ambient_sound(sample, flags);
}


qboolean MapProfileIsStrategicEventActive(void)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL &&
      profile->is_strategic_event_active != NULL &&
      profile->is_strategic_event_active();
}


qboolean MapProfileIsBotAtStrategicDestination(const bot_t &pBot)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL &&
      profile->is_bot_at_strategic_destination != NULL &&
      profile->is_bot_at_strategic_destination(pBot);
}


qboolean MapProfileIsStrategicGoal(const bot_t &pBot)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL && profile->is_strategic_goal != NULL &&
      profile->is_strategic_goal(pBot);
}


qboolean MapProfileEnsureStrategicGoal(bot_t &pBot)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL && profile->ensure_strategic_goal != NULL &&
      profile->ensure_strategic_goal(pBot);
}


qboolean MapProfileHandleSpecialMovement(bot_t &pBot)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL && profile->handle_special_movement != NULL &&
      profile->handle_special_movement(pBot);
}


qboolean MapProfileShouldYieldToStrategicMovement(const bot_t &pBot)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL &&
      profile->should_yield_to_strategic_movement != NULL &&
      profile->should_yield_to_strategic_movement(pBot);
}


qboolean MapProfileShouldPrioritizeCombat(const bot_t &pBot)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL && profile->should_prioritize_combat != NULL &&
      profile->should_prioritize_combat(pBot);
}


qboolean MapProfileCanNoticeCombatTarget(const bot_t &pBot,
   const edict_t *target)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL && profile->can_notice_combat_target != NULL &&
      profile->can_notice_combat_target(pBot, target);
}


const char *MapProfileGetActiveName(void)
{
   const map_profile_t *profile = MapProfileResolve();

   return profile != NULL && profile->name != NULL ? profile->name : "none";
}
