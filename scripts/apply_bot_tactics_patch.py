from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file_path = Path(path)
    text = file_path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one source block in {path}, found {count}")
    file_path.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_once(
    "bot_weapons.cpp",
    '''   {VALVE_WEAPON_CROWBAR, WEAPON_SUBMOD_ALL, "weapon_crowbar", WEAPON_MELEE, 1.0,
     SKILL4, NOSKILL, FALSE, FALSE,
     0.0, 40.0, 0, 0, 1.0,''',
    '''   {VALVE_WEAPON_CROWBAR, WEAPON_SUBMOD_ALL, "weapon_crowbar", WEAPON_MELEE, 1.0,
     SKILL4, NOSKILL, FALSE, FALSE,
     0.0, 64.0, 0, 0, 1.0,''',
)

replace_once(
    "bot_combat.cpp",
    '''// specifing a weapon_choice allows you to choose the weapon the bot will
// use (assuming enough ammo exists for that weapon)
// BotFireWeapon will return TRUE if weapon was fired, FALSE otherwise
static qboolean BotFireWeapon(const Vector & v_enemy, bot_t &pBot, int weapon_choice)
{''',
    '''static qboolean BotShouldUseCrowbarOverOnlyGlock(const bot_t &pBot, float distance, int weapon_choice)
{
   if (weapon_choice != 0 || distance > 64.0f || pBot.b_in_water)
      return FALSE;

   const unsigned int crowbar_bit = (1u << VALVE_WEAPON_CROWBAR);
   const unsigned int glock_bit = (1u << VALVE_WEAPON_GLOCK);
   const unsigned int carried = (unsigned int)pBot.pEdict->v.weapons;

   if ((carried & crowbar_bit) == 0 || (carried & glock_bit) == 0)
      return FALSE;

   const unsigned int allowed = crowbar_bit | glock_bit;
   return (carried & ~allowed) == 0 ? TRUE : FALSE;
}


// specifing a weapon_choice allows you to choose the weapon the bot will
// use (assuming enough ammo exists for that weapon)
// BotFireWeapon will return TRUE if weapon was fired, FALSE otherwise
static qboolean BotFireWeapon(const Vector & v_enemy, bot_t &pBot, int weapon_choice)
{''',
)

replace_once(
    "bot_combat.cpp",
    '''   float distance = v_enemy.Length();  // how far away is the enemy?
   float height = v_enemy.z; // how high is enemy?

   const bot_weapon_select_t *pSelect = &weapon_select[0];''',
    '''   float distance = v_enemy.Length();  // how far away is the enemy?
   float height = v_enemy.z; // how high is enemy?

   if (BotShouldUseCrowbarOverOnlyGlock(pBot, distance, weapon_choice))
      weapon_choice = VALVE_WEAPON_CROWBAR;

   const bot_weapon_select_t *pSelect = &weapon_select[0];''',
)

replace_once(
    "bot.cpp",
    '''static void BotFindItem_SetPickupTarget(bot_t &pBot, edict_t *pPickupEntity,
   const Vector &pickup_origin)''',
    '''static int BotFindItem_GetPriority(bot_t &pBot, const char *item_name)
{
   const qboolean just_respawned =
      pBot.f_bot_spawn_time > 0.0f && gpGlobals->time - pBot.f_bot_spawn_time <= 5.0f;

   if (GetWeaponItemFlag(item_name) != 0 || strcmp("weaponbox", item_name) == 0)
      return just_respawned ? 400 : 240;

   if (strcmp("item_battery", item_name) == 0)
      return 320;

   if (strcmp("item_healthkit", item_name) == 0)
      return 220;

   if (GetAmmoItemFlag(item_name) != 0)
      return 140;

   return 100;
}


static void BotFindItem_SetPickupTarget(bot_t &pBot, edict_t *pPickupEntity,
   const Vector &pickup_origin)''',
)

replace_once(
    "bot.cpp",
    '''   float min_distance;
   char item_name[40];''',
    '''   float min_distance;
   int best_priority = -1;
   char item_name[40];''',
)

replace_once(
    "bot.cpp",
    '''       if (can_pickup) // if the bot found something it can pickup...
       {
          float distance = (entity_origin - pEdict->v.origin).Length( );

          // see if it's the closest item so far...
          if (distance < min_distance)
          {
             min_distance = distance;        // update the minimum distance
             pPickupEntity = pent;        // remember this entity
             pickup_origin = entity_origin;  // remember location of entity
          }
       }''',
    '''       if (can_pickup) // if the bot found something it can pickup...
       {
          float distance = (entity_origin - pEdict->v.origin).Length( );
          int priority = BotFindItem_GetPriority(pBot, item_name);

          // Prefer tactically important items, then the nearest item within the
          // same priority class. Visibility and field-of-view checks still apply.
          if (priority > best_priority ||
              (priority == best_priority && distance < min_distance))
          {
             best_priority = priority;
             min_distance = distance;
             pPickupEntity = pent;
             pickup_origin = entity_origin;
          }
       }''',
)

print("Bot tactics patch applied successfully.")
