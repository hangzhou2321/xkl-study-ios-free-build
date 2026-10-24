#pragma once
#include <stdbool.h>
#include <stdint.h>
#define POCKET_WORD_COUNT 25644u
#define POCKET_DECK_ID UINT32_C(0x08da21a4)
typedef struct { const char *word; const char *pos; const char *meaning; } pocket_word_t;
/* Word/POS are immutable Flash; meaning uses a bounded buffer valid until the
 * next pocket_deck_get. Core/expanded lookups use separate buffers. */
bool pocket_deck_get(uint16_t id, pocket_word_t *out);
