//
// Crossfire-specific tactical behavior.
//

#ifndef CROSSFIRE_TACTICS_H
#define CROSSFIRE_TACTICS_H

void CrossfireTacticsReset(void);
void CrossfireTacticsOnAmbientSound(const char *sample, int flags);
qboolean CrossfireTacticsIsStrikeActive(void);
qboolean CrossfireTacticsIsBotSheltered(const bot_t &pBot);
int CrossfireTacticsFindBunkerWaypoint(const bot_t &pBot);

#endif // CROSSFIRE_TACTICS_H
