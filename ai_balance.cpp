//
// JK_Botti - slow AI balance bridge for HLDM bot lab
//

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <extdll.h>
#include <dllapi.h>
#include <h_export.h>
#include <meta_api.h>

#ifndef _WIN32
#include <sys/stat.h>
#include <unistd.h>
#endif

#include "bot.h"
#include "bot_func.h"
#include "bot_skill.h"
#include "player.h"
#include "safe_snprintf.h"
#include "util.h"

#include "ai_balance.h"

extern enginefuncs_t g_engfuncs;
extern globalvars_t *gpGlobals;
extern bot_t bots[32];
extern player_t players[32];
extern int default_bot_skill;
extern int submod_id;

typedef struct ai_balance_player_stats_s
{
   int deaths;
} ai_balance_player_stats_t;

typedef struct ai_balance_kill_event_s
{
   float game_time;
   qboolean killer_is_bot;
} ai_balance_kill_event_t;

typedef struct ai_balance_patch_s
{
   int schema_version;
   int telemetry_sequence;
   char match_id[96];
   char patch_id[96];
   char map_name[64];
   int target_skill_level;
   int bot_count_delta;
   float pause_frequency_scale;
   float battle_strafe_scale;
   char reason[160];
} ai_balance_patch_t;

typedef struct ai_balance_state_s
{
   qboolean cvars_registered;
   int telemetry_sequence;
   float next_telemetry_time;
   float next_patch_poll_time;
   float last_apply_time;
   char match_id[96];
   char last_applied_patch_id[96];
   float pause_frequency_scale;
   float battle_strafe_scale;
   ai_balance_player_stats_t player_stats[32];
   ai_balance_kill_event_t kill_events[256];
   int kill_event_head;
   int kill_event_count;
} ai_balance_state_t;

static ai_balance_state_t g_ai_balance;

static cvar_t jk_ai_balance_enabled = { "jk_ai_balance_enabled", "1", FCVAR_EXTDLL|FCVAR_SERVER, 0, NULL };
static cvar_t jk_ai_balance_interval = { "jk_ai_balance_interval", "20", FCVAR_EXTDLL, 0, NULL };
static cvar_t jk_ai_balance_cooldown = { "jk_ai_balance_cooldown", "30", FCVAR_EXTDLL, 0, NULL };
static cvar_t jk_ai_balance_debug = { "jk_ai_balance_debug", "0", FCVAR_EXTDLL, 0, NULL };

static float AiBalanceClampFloat(const float value, const float min_value, const float max_value)
{
   if (value < min_value)
      return min_value;
   if (value > max_value)
      return max_value;
   return value;
}

static int AiBalanceClampInt(const int value, const int min_value, const int max_value)
{
   if (value < min_value)
      return min_value;
   if (value > max_value)
      return max_value;
   return value;
}

static qboolean AiBalanceDebugEnabled(void)
{
   if (!g_ai_balance.cvars_registered)
      return FALSE;

   return (CVAR_GET_FLOAT("jk_ai_balance_debug") != 0.0f) ? TRUE : FALSE;
}

static void AiBalanceLog(const char *prefix, const char *fmt, ...)
{
   va_list argptr;
   char message[512];

   message[0] = 0;

   va_start(argptr, fmt);
   safevoid_vsnprintf(message, sizeof(message), fmt, argptr);
   va_end(argptr);

   if (prefix && *prefix)
      UTIL_ConsolePrintf("%s%s", prefix, message);
   else
      UTIL_ConsolePrintf("%s", message);
}

static void AiBalanceDebug(const char *fmt, ...)
{
   va_list argptr;
   char message[512];

   if (!AiBalanceDebugEnabled())
      return;

   message[0] = 0;

   va_start(argptr, fmt);
   safevoid_vsnprintf(message, sizeof(message), fmt, argptr);
   va_end(argptr);

   UTIL_ConsolePrintf("[ai_balance] %s", message);
}

static const char *AiBalanceGetModDir(void)
{
   return (submod_id == SUBMOD_OP4) ? "gearbox" : "valve";
}

static void AiBalanceBuildRuntimePath(char *path, const size_t path_size, const char *file_name)
{
   if (file_name && *file_name)
      safevoid_snprintf(path, path_size, "%s/addons/jk_botti/runtime/ai_balance/%s", AiBalanceGetModDir(), file_name);
   else
      safevoid_snprintf(path, path_size, "%s/addons/jk_botti/runtime/ai_balance", AiBalanceGetModDir());
}

static void AiBalanceBuildUtcTimestamp(char *timestamp, const size_t timestamp_size);

static qboolean AiBalanceCreateDirectoryIfMissing(const char *path)
{
#ifdef _WIN32
   if (CreateDirectoryA(path, NULL))
      return TRUE;

   if (GetLastError() == ERROR_ALREADY_EXISTS)
      return TRUE;

   return FALSE;
#else
   if (mkdir(path, 0777) == 0)
      return TRUE;

   if (errno == EEXIST)
      return TRUE;

   return FALSE;
#endif
}

static qboolean AiBalanceEnsureRuntimeDir(void)
{
   char runtime_dir[512];
   char partial[512];
   size_t i;
   size_t pos = 0;

   AiBalanceBuildRuntimePath(runtime_dir, sizeof(runtime_dir), NULL);

   memset(partial, 0, sizeof(partial));

   for (i = 0; runtime_dir[i] != 0 && pos + 1 < sizeof(partial); i++)
   {
      partial[pos++] = runtime_dir[i];
      partial[pos] = 0;

      if (runtime_dir[i] == '/' || runtime_dir[i] == '\\')
      {
         if (pos > 1)
            AiBalanceCreateDirectoryIfMissing(partial);
      }
   }

   return AiBalanceCreateDirectoryIfMissing(partial);
}

static void AiBalanceSanitizePathToken(const char *value, char *token, const size_t token_size)
{
   size_t idx;
   size_t outpos = 0;

   if (token_size == 0)
      return;

   if (value == NULL || *value == 0)
      value = "unknown-match";

   for (idx = 0; value[idx] != 0 && outpos + 1 < token_size; idx++)
   {
      const unsigned char ch = (unsigned char)value[idx];

      if (isalnum(ch) || ch == '-' || ch == '_' || ch == '.')
         token[outpos++] = (char)ch;
      else
         token[outpos++] = '_';
   }

   token[outpos] = 0;
}

static void AiBalanceBuildHistoryPath(char *path, const size_t path_size, const char *prefix)
{
   char match_token[128];

   AiBalanceSanitizePathToken(g_ai_balance.match_id, match_token, sizeof(match_token));
   safevoid_snprintf(path, path_size, "%s/addons/jk_botti/runtime/ai_balance/history/%s-%s.ndjson",
      AiBalanceGetModDir(),
      prefix,
      match_token);
}

static qboolean AiBalanceEnsureHistoryDir(void)
{
   char history_dir[512];

   if (!AiBalanceEnsureRuntimeDir())
      return FALSE;

   AiBalanceBuildRuntimePath(history_dir, sizeof(history_dir), "history");
   return AiBalanceCreateDirectoryIfMissing(history_dir);
}

static qboolean AiBalanceAppendLine(const char *path, const char *line)
{
   FILE *fp;
   size_t expected_size;

   fp = fopen(path, "ab");
   if (fp == NULL)
      return FALSE;

   expected_size = strlen(line);
   if (expected_size > 0 && fwrite(line, 1, expected_size, fp) != expected_size)
   {
      fclose(fp);
      return FALSE;
   }

   if (fwrite("\n", 1, 1, fp) != 1)
   {
      fclose(fp);
      return FALSE;
   }

   fclose(fp);
   return TRUE;
}

static void AiBalanceJsonEscapeString(const char *value, char *escaped, const size_t escaped_size)
{
   size_t idx;
   size_t outpos = 0;

   if (escaped_size == 0)
      return;

   if (value == NULL)
      value = "";

   for (idx = 0; value[idx] != 0 && outpos + 1 < escaped_size; idx++)
   {
      const char ch = value[idx];

      if (ch == '"' || ch == '\\')
      {
         if (outpos + 2 >= escaped_size)
            break;

         escaped[outpos++] = '\\';
         escaped[outpos++] = ch;
         continue;
      }

      if (ch == '\n' || ch == '\r' || ch == '\t')
      {
         if (outpos + 2 >= escaped_size)
            break;

         escaped[outpos++] = '\\';
         escaped[outpos++] = (ch == '\n') ? 'n' : (ch == '\r' ? 'r' : 't');
         continue;
      }

      if ((unsigned char)ch < 32)
      {
         escaped[outpos++] = ' ';
         continue;
      }

      escaped[outpos++] = ch;
   }

   escaped[outpos] = 0;
}

static void AiBalanceBuildAdjustmentDirection(char *direction, const size_t direction_size,
   const int previous_skill_level, const int effective_skill_level,
   const int applied_bot_delta,
   const float pause_frequency_scale, const float battle_strafe_scale)
{
   if (effective_skill_level < previous_skill_level ||
      applied_bot_delta > 0 ||
      pause_frequency_scale < 1.0f ||
      battle_strafe_scale > 1.0f)
   {
      safe_strcopy(direction, direction_size, "strengthen");
      return;
   }

   if (effective_skill_level > previous_skill_level ||
      applied_bot_delta < 0 ||
      pause_frequency_scale > 1.0f ||
      battle_strafe_scale < 1.0f)
   {
      safe_strcopy(direction, direction_size, "relax");
      return;
   }

   safe_strcopy(direction, direction_size, "hold");
}

static void AiBalanceAppendPatchApplyHistory(const ai_balance_patch_t *patch,
   const int previous_skill_level, const int effective_skill_level,
   const int applied_bot_delta, const float cooldown_seconds)
{
   char timestamp[64];
   char history_path[512];
   char direction[32];
   char history_json[2048];
   char escaped_match_id[192];
   char escaped_patch_id[192];
   char escaped_map_name[128];
   char escaped_reason[320];

   if (!AiBalanceEnsureHistoryDir())
      return;

   AiBalanceBuildUtcTimestamp(timestamp, sizeof(timestamp));
   AiBalanceBuildHistoryPath(history_path, sizeof(history_path), "patch_apply");
   AiBalanceBuildAdjustmentDirection(direction, sizeof(direction),
      previous_skill_level, effective_skill_level, applied_bot_delta,
      patch->pause_frequency_scale, patch->battle_strafe_scale);
   AiBalanceJsonEscapeString(g_ai_balance.match_id, escaped_match_id, sizeof(escaped_match_id));
   AiBalanceJsonEscapeString(patch->patch_id, escaped_patch_id, sizeof(escaped_patch_id));
   AiBalanceJsonEscapeString(
      patch->map_name[0] ? patch->map_name : (gpGlobals ? STRING(gpGlobals->mapname) : "unknown"),
      escaped_map_name,
      sizeof(escaped_map_name));
   AiBalanceJsonEscapeString(patch->reason[0] ? patch->reason : "n/a", escaped_reason, sizeof(escaped_reason));

   safevoid_snprintf(history_json, sizeof(history_json),
      "{\"schema_version\":1,\"event_type\":\"patch_applied\",\"match_id\":\"%s\",\"patch_id\":\"%s\","
      "\"telemetry_sequence\":%d,\"timestamp_utc\":\"%s\",\"server_time_seconds\":%.2f,"
      "\"map_name\":\"%s\",\"previous_default_bot_skill_level\":%d,"
      "\"effective_default_bot_skill_level\":%d,\"target_skill_level\":%d,"
      "\"requested_bot_count_delta\":%d,\"applied_bot_count_delta\":%d,"
      "\"pause_frequency_scale\":%.3f,\"battle_strafe_scale\":%.3f,"
      "\"cooldown_seconds\":%.1f,\"direction\":\"%s\",\"reason\":\"%s\"}",
      escaped_match_id,
      escaped_patch_id,
      patch->telemetry_sequence,
      timestamp,
      gpGlobals ? gpGlobals->time : 0.0f,
      escaped_map_name,
      previous_skill_level,
      effective_skill_level,
      patch->target_skill_level,
      patch->bot_count_delta,
      applied_bot_delta,
      patch->pause_frequency_scale,
      patch->battle_strafe_scale,
      cooldown_seconds,
      direction,
      escaped_reason);

   AiBalanceAppendLine(history_path, history_json);
}

static void AiBalanceAppendBotSettingsHistory(const ai_balance_patch_t *patch,
   const int effective_skill_level, const int applied_bot_delta)
{
   char timestamp[64];
   char history_path[512];
   char history_json[1024];
   char escaped_match_id[192];
   char escaped_patch_id[192];
   char escaped_map_name[128];

   if (!AiBalanceEnsureHistoryDir())
      return;

   AiBalanceBuildUtcTimestamp(timestamp, sizeof(timestamp));
   AiBalanceBuildHistoryPath(history_path, sizeof(history_path), "bot_settings");
   AiBalanceJsonEscapeString(g_ai_balance.match_id, escaped_match_id, sizeof(escaped_match_id));
   AiBalanceJsonEscapeString(patch->patch_id, escaped_patch_id, sizeof(escaped_patch_id));
   AiBalanceJsonEscapeString(
      patch->map_name[0] ? patch->map_name : (gpGlobals ? STRING(gpGlobals->mapname) : "unknown"),
      escaped_map_name,
      sizeof(escaped_map_name));

   safevoid_snprintf(history_json, sizeof(history_json),
      "{\"schema_version\":1,\"event_type\":\"bot_settings\",\"source\":\"patch_apply\","
      "\"match_id\":\"%s\",\"patch_id\":\"%s\",\"telemetry_sequence\":%d,"
      "\"timestamp_utc\":\"%s\",\"server_time_seconds\":%.2f,\"map_name\":\"%s\","
      "\"default_bot_skill_level\":%d,\"active_bot_count\":%d,\"applied_bot_count_delta\":%d,"
      "\"pause_frequency_scale\":%.3f,\"battle_strafe_scale\":%.3f}",
      escaped_match_id,
      escaped_patch_id,
      patch->telemetry_sequence,
      timestamp,
      gpGlobals ? gpGlobals->time : 0.0f,
      escaped_map_name,
      effective_skill_level,
      UTIL_GetBotCount(),
      applied_bot_delta,
      g_ai_balance.pause_frequency_scale,
      g_ai_balance.battle_strafe_scale);

   AiBalanceAppendLine(history_path, history_json);
}

static qboolean AiBalanceWriteFileAtomic(const char *path, const char *contents)
{
   char temp_path[512];
   FILE *fp;
   size_t expected_size;

   safevoid_snprintf(temp_path, sizeof(temp_path), "%s.tmp", path);

   fp = fopen(temp_path, "wb");
   if (fp == NULL)
      return FALSE;

   expected_size = strlen(contents);
   if (expected_size > 0 && fwrite(contents, 1, expected_size, fp) != expected_size)
   {
      fclose(fp);
      remove(temp_path);
      return FALSE;
   }

   fclose(fp);

#ifdef _WIN32
   if (!MoveFileExA(temp_path, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
   {
      remove(temp_path);
      return FALSE;
   }
#else
   if (rename(temp_path, path) != 0)
   {
      remove(temp_path);
      return FALSE;
   }
#endif

   return TRUE;
}

static qboolean AiBalanceReadFile(const char *path, char *contents, const size_t contents_size)
{
   FILE *fp;
   size_t bytes_read;
   size_t bytes_total = 0;

   if (contents_size == 0)
      return FALSE;

   fp = fopen(path, "rb");
   if (fp == NULL)
      return FALSE;

   contents[0] = 0;

   while (!feof(fp) && bytes_total + 1 < contents_size)
   {
      bytes_read = fread(contents + bytes_total, 1, contents_size - bytes_total - 1, fp);
      if (bytes_read == 0)
         break;
      bytes_total += bytes_read;
   }

   contents[bytes_total] = 0;
   fclose(fp);

   return (bytes_total > 0) ? TRUE : FALSE;
}

static const char *AiBalanceFindJsonValue(const char *json, const char *key)
{
   char pattern[128];
   const char *pos;

   safevoid_snprintf(pattern, sizeof(pattern), "\"%s\"", key);
   pos = strstr(json, pattern);
   if (pos == NULL)
      return NULL;

   pos = strchr(pos + strlen(pattern), ':');
   if (pos == NULL)
      return NULL;

   pos++;
   while (*pos && isspace((unsigned char)*pos))
      pos++;

   return pos;
}

static qboolean AiBalanceJsonExtractInt(const char *json, const char *key, int *value)
{
   const char *pos = AiBalanceFindJsonValue(json, key);
   char *endptr = NULL;
   long parsed;

   if (pos == NULL)
      return FALSE;

   parsed = strtol(pos, &endptr, 10);
   if (endptr == pos)
      return FALSE;

   *value = (int)parsed;
   return TRUE;
}

static qboolean AiBalanceJsonExtractFloat(const char *json, const char *key, float *value)
{
   const char *pos = AiBalanceFindJsonValue(json, key);
   char *endptr = NULL;
   double parsed;

   if (pos == NULL)
      return FALSE;

   parsed = strtod(pos, &endptr);
   if (endptr == pos)
      return FALSE;

   *value = (float)parsed;
   return TRUE;
}

static qboolean AiBalanceJsonExtractString(const char *json, const char *key, char *value, const size_t value_size)
{
   const char *pos = AiBalanceFindJsonValue(json, key);
   size_t outpos = 0;

   if (pos == NULL || value_size == 0)
      return FALSE;

   if (*pos != '"')
      return FALSE;

   pos++;

   while (*pos && *pos != '"' && outpos + 1 < value_size)
   {
      if (*pos == '\\' && pos[1] != 0)
      {
         pos++;

         if (*pos == 'n' || *pos == 'r' || *pos == 't')
            value[outpos++] = ' ';
         else
            value[outpos++] = *pos;

         pos++;
         continue;
      }

      value[outpos++] = *pos++;
   }

   if (*pos != '"')
      return FALSE;

   value[outpos] = 0;
   return TRUE;
}

static qboolean AiBalanceIsBotEdict(const edict_t *pEntity)
{
   if (pEntity == NULL || FNullEnt((edict_t *)pEntity))
      return FALSE;

   if (FBitSet(pEntity->v.flags, FL_FAKECLIENT) || FBitSet(pEntity->v.flags, FL_THIRDPARTYBOT))
      return TRUE;

   return (UTIL_GetBotIndex(pEntity) != -1) ? TRUE : FALSE;
}

static qboolean AiBalanceIsConnectedClient(const edict_t *pEntity)
{
   if (pEntity == NULL || FNullEnt((edict_t *)pEntity))
      return FALSE;

   if (pEntity->free)
      return FALSE;

   if (!FBitSet(pEntity->v.flags, FL_CLIENT))
      return FALSE;

   return TRUE;
}

static void AiBalancePushKillEvent(const qboolean killer_is_bot)
{
   ai_balance_kill_event_t *event;

   event = &g_ai_balance.kill_events[g_ai_balance.kill_event_head];
   event->game_time = gpGlobals ? gpGlobals->time : 0.0f;
   event->killer_is_bot = killer_is_bot;

   g_ai_balance.kill_event_head = (g_ai_balance.kill_event_head + 1) % (int)(sizeof(g_ai_balance.kill_events) / sizeof(g_ai_balance.kill_events[0]));
   if (g_ai_balance.kill_event_count < (int)(sizeof(g_ai_balance.kill_events) / sizeof(g_ai_balance.kill_events[0])))
      g_ai_balance.kill_event_count++;
}

static int AiBalanceCountRecentKills(const qboolean killer_is_bot)
{
   int count = 0;
   int idx;
   int event_count;
   float now;

   if (!gpGlobals)
      return 0;

   now = gpGlobals->time;
   event_count = g_ai_balance.kill_event_count;

   for (idx = 0; idx < event_count; idx++)
   {
      int offset = g_ai_balance.kill_event_head - 1 - idx;
      ai_balance_kill_event_t *event;

      if (offset < 0)
         offset += (int)(sizeof(g_ai_balance.kill_events) / sizeof(g_ai_balance.kill_events[0]));

      event = &g_ai_balance.kill_events[offset];

      if (now - event->game_time > 60.0f)
         break;

      if (event->killer_is_bot == killer_is_bot)
         count++;
   }

   return count;
}

static void AiBalanceSummarizeScoreboard(int *human_count, int *bot_count,
   int *top_human_frags, int *top_human_deaths,
   int *top_bot_frags, int *top_bot_deaths)
{
   int idx;

   *human_count = 0;
   *bot_count = 0;
   *top_human_frags = 0;
   *top_human_deaths = 0;
   *top_bot_frags = 0;
   *top_bot_deaths = 0;

   for (idx = 0; idx < 32; idx++)
   {
      edict_t *pEntity = players[idx].pEdict;
      int frags;
      int deaths;

      if (!AiBalanceIsConnectedClient(pEntity))
         continue;

      frags = (int)pEntity->v.frags;
      deaths = g_ai_balance.player_stats[idx].deaths;

      if (AiBalanceIsBotEdict(pEntity))
      {
         (*bot_count)++;
         if (frags > *top_bot_frags)
            *top_bot_frags = frags;
         if (deaths > *top_bot_deaths)
            *top_bot_deaths = deaths;
      }
      else
      {
         (*human_count)++;
         if (frags > *top_human_frags)
            *top_human_frags = frags;
         if (deaths > *top_human_deaths)
            *top_human_deaths = deaths;
      }
   }
}

static void AiBalanceBuildUtcTimestamp(char *timestamp, const size_t timestamp_size)
{
   time_t now = time(NULL);
   struct tm *utc = gmtime(&now);

   if (utc == NULL)
   {
      safe_strcopy(timestamp, timestamp_size, "");
      return;
   }

   strftime(timestamp, timestamp_size, "%Y-%m-%dT%H:%M:%SZ", utc);
}

static void AiBalanceBuildMatchId(void)
{
   const char *map_name = gpGlobals ? STRING(gpGlobals->mapname) : "unknown";
   safevoid_snprintf(g_ai_balance.match_id, sizeof(g_ai_balance.match_id), "%s-%ld", map_name, (long)time(NULL));
}

static void AiBalanceWriteTelemetry(void)
{
   char timestamp[64];
   char telemetry_path[512];
   char telemetry_json[4096];
   char telemetry_history_path[512];
   char telemetry_history_json[2048];
   int human_count;
   int bot_count;
   int top_human_frags;
   int top_human_deaths;
   int top_bot_frags;
   int top_bot_deaths;
   int human_kpm;
   int bot_kpm;
   int frag_gap;
   float interval_seconds;
   float cooldown_seconds;

   if (!gpGlobals)
      return;

   if (!AiBalanceEnsureRuntimeDir())
   {
      AiBalanceDebug("could not create runtime directory");
      return;
   }

   AiBalanceSummarizeScoreboard(&human_count, &bot_count,
      &top_human_frags, &top_human_deaths,
      &top_bot_frags, &top_bot_deaths);

   human_kpm = AiBalanceCountRecentKills(FALSE);
   bot_kpm = AiBalanceCountRecentKills(TRUE);
   frag_gap = top_human_frags - top_bot_frags;

   g_ai_balance.telemetry_sequence++;
   AiBalanceBuildUtcTimestamp(timestamp, sizeof(timestamp));
   AiBalanceBuildRuntimePath(telemetry_path, sizeof(telemetry_path), "telemetry.json");

   interval_seconds = AiBalanceClampFloat(CVAR_GET_FLOAT("jk_ai_balance_interval"), 5.0f, 120.0f);
   cooldown_seconds = AiBalanceClampFloat(CVAR_GET_FLOAT("jk_ai_balance_cooldown"), 20.0f, 60.0f);

   safevoid_snprintf(telemetry_json, sizeof(telemetry_json),
      "{\n"
      "  \"schema_version\": 1,\n"
      "  \"match_id\": \"%s\",\n"
      "  \"telemetry_sequence\": %d,\n"
      "  \"timestamp_utc\": \"%s\",\n"
      "  \"server_time_seconds\": %.2f,\n"
      "  \"map_name\": \"%s\",\n"
      "  \"human_player_count\": %d,\n"
      "  \"bot_count\": %d,\n"
      "  \"top_human_frags\": %d,\n"
      "  \"top_human_deaths\": %d,\n"
      "  \"top_bot_frags\": %d,\n"
      "  \"top_bot_deaths\": %d,\n"
      "  \"recent_human_kills_per_minute\": %d,\n"
      "  \"recent_bot_kills_per_minute\": %d,\n"
      "  \"frag_gap_top_human_minus_top_bot\": %d,\n"
      "  \"current_default_bot_skill_level\": %d,\n"
      "  \"active_balance\": {\n"
      "    \"pause_frequency_scale\": %.3f,\n"
      "    \"battle_strafe_scale\": %.3f,\n"
      "    \"interval_seconds\": %.1f,\n"
      "    \"cooldown_seconds\": %.1f,\n"
      "    \"enabled\": %d\n"
      "  }\n"
      "}\n",
      g_ai_balance.match_id,
      g_ai_balance.telemetry_sequence,
      timestamp,
      gpGlobals->time,
      STRING(gpGlobals->mapname),
      human_count,
      bot_count,
      top_human_frags,
      top_human_deaths,
      top_bot_frags,
      top_bot_deaths,
      human_kpm,
      bot_kpm,
      frag_gap,
      AiBalanceClampInt(default_bot_skill, 1, 5),
      g_ai_balance.pause_frequency_scale,
      g_ai_balance.battle_strafe_scale,
      interval_seconds,
      cooldown_seconds,
      CVAR_GET_FLOAT("jk_ai_balance_enabled") != 0.0f ? 1 : 0);

   if (!AiBalanceWriteFileAtomic(telemetry_path, telemetry_json))
      AiBalanceDebug("failed to write telemetry to %s", telemetry_path);

   if (!AiBalanceEnsureHistoryDir())
      return;

   AiBalanceBuildHistoryPath(telemetry_history_path, sizeof(telemetry_history_path), "telemetry");
   safevoid_snprintf(telemetry_history_json, sizeof(telemetry_history_json),
      "{\"schema_version\":1,\"event_type\":\"telemetry\",\"match_id\":\"%s\","
      "\"telemetry_sequence\":%d,\"timestamp_utc\":\"%s\",\"server_time_seconds\":%.2f,"
      "\"map_name\":\"%s\",\"human_player_count\":%d,\"bot_count\":%d,"
      "\"top_human_frags\":%d,\"top_human_deaths\":%d,\"top_bot_frags\":%d,\"top_bot_deaths\":%d,"
      "\"recent_human_kills_per_minute\":%d,\"recent_bot_kills_per_minute\":%d,"
      "\"frag_gap_top_human_minus_top_bot\":%d,\"current_default_bot_skill_level\":%d,"
      "\"active_balance\":{\"pause_frequency_scale\":%.3f,\"battle_strafe_scale\":%.3f,"
      "\"interval_seconds\":%.1f,\"cooldown_seconds\":%.1f,\"enabled\":%d}}",
      g_ai_balance.match_id,
      g_ai_balance.telemetry_sequence,
      timestamp,
      gpGlobals->time,
      STRING(gpGlobals->mapname),
      human_count,
      bot_count,
      top_human_frags,
      top_human_deaths,
      top_bot_frags,
      top_bot_deaths,
      human_kpm,
      bot_kpm,
      frag_gap,
      AiBalanceClampInt(default_bot_skill, 1, 5),
      g_ai_balance.pause_frequency_scale,
      g_ai_balance.battle_strafe_scale,
      interval_seconds,
      cooldown_seconds,
      CVAR_GET_FLOAT("jk_ai_balance_enabled") != 0.0f ? 1 : 0);

   AiBalanceAppendLine(telemetry_history_path, telemetry_history_json);
}

static qboolean AiBalanceParsePatch(const char *json, ai_balance_patch_t *patch)
{
   memset(patch, 0, sizeof(*patch));

   if (!AiBalanceJsonExtractInt(json, "schema_version", &patch->schema_version))
      return FALSE;
   if (!AiBalanceJsonExtractInt(json, "telemetry_sequence", &patch->telemetry_sequence))
      return FALSE;
   if (!AiBalanceJsonExtractInt(json, "target_skill_level", &patch->target_skill_level))
      return FALSE;
   if (!AiBalanceJsonExtractInt(json, "bot_count_delta", &patch->bot_count_delta))
      return FALSE;
   if (!AiBalanceJsonExtractFloat(json, "pause_frequency_scale", &patch->pause_frequency_scale))
      return FALSE;
   if (!AiBalanceJsonExtractFloat(json, "battle_strafe_scale", &patch->battle_strafe_scale))
      return FALSE;
   if (!AiBalanceJsonExtractString(json, "match_id", patch->match_id, sizeof(patch->match_id)))
      return FALSE;
   if (!AiBalanceJsonExtractString(json, "patch_id", patch->patch_id, sizeof(patch->patch_id)))
      return FALSE;

   if (!AiBalanceJsonExtractString(json, "map_name", patch->map_name, sizeof(patch->map_name)))
      patch->map_name[0] = 0;

   if (!AiBalanceJsonExtractString(json, "reason", patch->reason, sizeof(patch->reason)))
      patch->reason[0] = 0;

   patch->schema_version = AiBalanceClampInt(patch->schema_version, 1, 1);
   patch->target_skill_level = AiBalanceClampInt(patch->target_skill_level, 1, 5);
   patch->bot_count_delta = AiBalanceClampInt(patch->bot_count_delta, -1, 1);
   patch->pause_frequency_scale = AiBalanceClampFloat(patch->pause_frequency_scale, 0.85f, 1.15f);
   patch->battle_strafe_scale = AiBalanceClampFloat(patch->battle_strafe_scale, 0.85f, 1.15f);

   return TRUE;
}

static int AiBalanceApplySkillPatchStep(const int target_skill_level)
{
   int current_skill_level = AiBalanceClampInt(default_bot_skill, 1, 5);
   int next_skill_level = current_skill_level;
   int changed_bots = 0;
   int idx;

   if (target_skill_level < current_skill_level)
      next_skill_level--;
   else if (target_skill_level > current_skill_level)
      next_skill_level++;

   next_skill_level = AiBalanceClampInt(next_skill_level, 1, 5);

   if (next_skill_level == current_skill_level)
      return 0;

   default_bot_skill = next_skill_level;

   for (idx = 0; idx < 32; idx++)
   {
      int bot_skill_level;

      if (!bots[idx].is_used)
         continue;

      bot_skill_level = AiBalanceClampInt(bots[idx].bot_skill + 1, 1, 5);

      if (bot_skill_level < next_skill_level)
         bot_skill_level++;
      else if (bot_skill_level > next_skill_level)
         bot_skill_level--;

      bot_skill_level = AiBalanceClampInt(bot_skill_level, 1, 5);

      bots[idx].bot_skill = bot_skill_level - 1;
      bots[idx].weapon_skill = bot_skill_level;
      changed_bots++;
   }

   AiBalanceDebug("skill level stepped to %d, updated %d active bots", next_skill_level, changed_bots);
   return next_skill_level;
}

static int AiBalanceApplyBotCountDelta(const int bot_count_delta)
{
   int client_count;
   int bot_count;

   if (bot_count_delta == 0)
      return 0;

   client_count = UTIL_GetClientCount();
   bot_count = UTIL_GetBotCount();

   if (bot_count_delta > 0)
   {
      if (client_count < gpGlobals->maxClients)
      {
         BotCreate(NULL, NULL, -1, -1, -1, -1);
         return 1;
      }

      AiBalanceDebug("bot add skipped because server is full");
      return 0;
   }

   if (bot_count <= 0)
   {
      AiBalanceDebug("bot remove skipped because there are no active bots");
      return 0;
   }

   {
      int pick = UTIL_PickRandomBot();
      if (pick != -1)
      {
         BotKick(bots[pick]);
         return -1;
      }
   }

   return 0;
}

static void AiBalanceApplyPatch(const ai_balance_patch_t *patch)
{
   int applied_skill_level;
   int previous_skill_level;
   int effective_skill_level;
   int applied_bot_delta;
   float cooldown_seconds;

   previous_skill_level = AiBalanceClampInt(default_bot_skill, 1, 5);
   applied_skill_level = AiBalanceApplySkillPatchStep(patch->target_skill_level);
   applied_bot_delta = AiBalanceApplyBotCountDelta(patch->bot_count_delta);
   effective_skill_level = applied_skill_level ? applied_skill_level : AiBalanceClampInt(default_bot_skill, 1, 5);

   g_ai_balance.pause_frequency_scale = patch->pause_frequency_scale;
   g_ai_balance.battle_strafe_scale = patch->battle_strafe_scale;
   BotSkillSetBalanceScales(g_ai_balance.pause_frequency_scale, g_ai_balance.battle_strafe_scale);

   safe_strcopy(g_ai_balance.last_applied_patch_id, sizeof(g_ai_balance.last_applied_patch_id), patch->patch_id);
   g_ai_balance.last_apply_time = gpGlobals ? gpGlobals->time : 0.0f;
   cooldown_seconds = AiBalanceClampFloat(CVAR_GET_FLOAT("jk_ai_balance_cooldown"), 20.0f, 60.0f);

   AiBalanceLog("[ai_balance] ",
      "applied patch=%s target_skill=%d effective_skill=%d bot_delta=%d pause_scale=%.2f battle_strafe_scale=%.2f reason=%s",
      patch->patch_id,
      patch->target_skill_level,
      effective_skill_level,
      applied_bot_delta,
      g_ai_balance.pause_frequency_scale,
      g_ai_balance.battle_strafe_scale,
      patch->reason[0] ? patch->reason : "n/a");

   AiBalanceAppendPatchApplyHistory(patch, previous_skill_level, effective_skill_level, applied_bot_delta, cooldown_seconds);
   AiBalanceAppendBotSettingsHistory(patch, effective_skill_level, applied_bot_delta);
}

static void AiBalancePollPatch(void)
{
   char patch_path[512];
   char patch_json[4096];
   ai_balance_patch_t patch;
   float cooldown_seconds;

   if (!AiBalanceEnsureRuntimeDir())
      return;

   AiBalanceBuildRuntimePath(patch_path, sizeof(patch_path), "patch.json");
   if (!AiBalanceReadFile(patch_path, patch_json, sizeof(patch_json)))
      return;

   if (!AiBalanceParsePatch(patch_json, &patch))
   {
      AiBalanceDebug("ignoring invalid patch payload");
      return;
   }

   if (strcmp(patch.match_id, g_ai_balance.match_id) != 0)
   {
      AiBalanceDebug("ignoring patch for stale match_id=%s", patch.match_id);
      return;
   }

   if (patch.map_name[0] != 0 && stricmp(patch.map_name, STRING(gpGlobals->mapname)) != 0)
   {
      AiBalanceDebug("ignoring patch for stale map=%s", patch.map_name);
      return;
   }

   if (strcmp(patch.patch_id, g_ai_balance.last_applied_patch_id) == 0)
      return;

   cooldown_seconds = AiBalanceClampFloat(CVAR_GET_FLOAT("jk_ai_balance_cooldown"), 20.0f, 60.0f);
   if (gpGlobals->time - g_ai_balance.last_apply_time < cooldown_seconds)
   {
      AiBalanceDebug("cooldown active, deferring patch=%s", patch.patch_id);
      return;
   }

   AiBalanceApplyPatch(&patch);
}

void AiBalanceRegisterCvars(void)
{
   if (g_ai_balance.cvars_registered)
      return;

   CVAR_REGISTER(&jk_ai_balance_enabled);
   CVAR_REGISTER(&jk_ai_balance_interval);
   CVAR_REGISTER(&jk_ai_balance_cooldown);
   CVAR_REGISTER(&jk_ai_balance_debug);

   g_ai_balance.cvars_registered = TRUE;
   g_ai_balance.pause_frequency_scale = 1.0f;
   g_ai_balance.battle_strafe_scale = 1.0f;
   BotSkillSetBalanceScales(1.0f, 1.0f);
}

void AiBalanceOnMapStart(void)
{
   qboolean had_cvars = g_ai_balance.cvars_registered;

   memset(&g_ai_balance, 0, sizeof(g_ai_balance));
   g_ai_balance.cvars_registered = had_cvars;
   g_ai_balance.pause_frequency_scale = 1.0f;
   g_ai_balance.battle_strafe_scale = 1.0f;
   g_ai_balance.last_apply_time = -9999.0f;

   BotSkillSetBalanceScales(1.0f, 1.0f);
   AiBalanceBuildMatchId();
}

void AiBalanceOnClientPutInServer(edict_t *pEntity)
{
   int idx;

   if (!gpGlobals || !AiBalanceIsConnectedClient(pEntity))
      return;

   idx = ENTINDEX(pEntity) - 1;
   if (idx < 0 || idx >= 32)
      return;

   g_ai_balance.player_stats[idx].deaths = 0;
}

void AiBalanceOnClientDisconnect(edict_t *pEntity)
{
   int idx;

   if (pEntity == NULL || FNullEnt(pEntity))
      return;

   idx = ENTINDEX(pEntity) - 1;
   if (idx < 0 || idx >= 32)
      return;

   g_ai_balance.player_stats[idx].deaths = 0;
}

void AiBalanceOnDeathMsg(int killer_index, int victim_index)
{
   edict_t *killer_edict;
   int victim_slot;

   if (!gpGlobals)
      return;

   victim_slot = victim_index - 1;
   if (victim_slot >= 0 && victim_slot < 32)
      g_ai_balance.player_stats[victim_slot].deaths++;

   if (killer_index <= 0 || killer_index == victim_index)
      return;

   killer_edict = INDEXENT(killer_index);
   if (killer_edict == NULL || FNullEnt(killer_edict))
      return;

   AiBalancePushKillEvent(AiBalanceIsBotEdict(killer_edict));
}

void AiBalanceStartFrame(void)
{
   float interval_seconds;

   if (!gpGlobals || !g_ai_balance.cvars_registered)
      return;

   interval_seconds = AiBalanceClampFloat(CVAR_GET_FLOAT("jk_ai_balance_interval"), 5.0f, 120.0f);

   if (g_ai_balance.next_telemetry_time <= gpGlobals->time)
   {
      AiBalanceWriteTelemetry();
      g_ai_balance.next_telemetry_time = gpGlobals->time + interval_seconds;
   }

   if (CVAR_GET_FLOAT("jk_ai_balance_enabled") == 0.0f)
      return;

   if (g_ai_balance.next_patch_poll_time <= gpGlobals->time)
   {
      AiBalancePollPatch();
      g_ai_balance.next_patch_poll_time = gpGlobals->time + interval_seconds;
   }
}
