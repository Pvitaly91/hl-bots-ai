#ifndef AI_BALANCE_H
#define AI_BALANCE_H

#include <extdll.h>

void AiBalanceRegisterCvars(void);
void AiBalanceOnMapStart(void);
void AiBalanceOnClientPutInServer(edict_t *pEntity);
void AiBalanceOnClientDisconnect(edict_t *pEntity);
void AiBalanceOnDeathMsg(int killer_index, int victim_index);
void AiBalanceStartFrame(void);

#endif
