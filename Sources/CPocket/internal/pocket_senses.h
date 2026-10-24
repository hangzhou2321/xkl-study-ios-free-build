#pragma once
#include "pocket_deck.h"
#define POCKET_CORE_COUNT 43668u
#define POCKET_CORE_DECK_ID UINT32_C(0xf2cd769a)
#define POCKET_CORE_TARGET_VERSION "f2cd769a16d4d32f8445afc84b7bf049082461a8588ae39e21969848c75d8aeb"
#define POCKET_CORE_CARD_COUNT (POCKET_WORD_COUNT + POCKET_CORE_COUNT)
enum { POCKET_CUE_NONE = 0, POCKET_CUE_EXAMPLE = 1, POCKET_CUE_PATTERN = 2,
       POCKET_CUE_ENGLISH_DEFINITION = 3, POCKET_CUE_AUTHORED = 4 };
typedef struct { uint16_t word, index; uint8_t cue_kind; const char *pos, *meaning, *cue; } pocket_core_t;
/* Single-worker API: core meaning/cue buffers are valid until the next
 * pocket_core_get call. Word/POS pointers remain immutable Flash strings.
 * deck_get and word_expanded use separate buffers and preserve core pointers.
 * A decode error or insufficient buffer returns false/NULL, never truncation. */
bool pocket_core_get(uint16_t unit, pocket_core_t *out);
/* Index-only queries do not decompress text or invalidate returned strings. */
uint16_t pocket_core_word(uint16_t unit);
uint16_t pocket_word_core_begin(uint16_t word);
uint16_t pocket_word_core_end(uint16_t word);
/* Expanded text is valid until the next call to this getter. */
const char *pocket_word_expanded(uint16_t word);
