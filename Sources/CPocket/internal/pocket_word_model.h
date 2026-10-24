#pragma once
#include "pocket_model.h"
#include "pocket_word_targets.h"

#define POCKET_WORD_MAGIC UINT32_C(0x584b5757)
#define POCKET_WORD_VERSION 7u
#define POCKET_WORD_PARTIAL_PENDING (UINT32_C(1) << 23)
#define POCKET_WORD_PARTIAL_GAP 3u

/* Keep the original word IDs and checkpoint layout. Bit 23 belongs to this
 * independent word schema, not to the v7 sense model's UNASSESSED flag. */
typedef pocket_cached_t pocket_word_cached_t;
typedef pocket_body_t pocket_word_body_t;
typedef pocket_state_t pocket_word_state_t;
typedef pocket_read_fn pocket_word_read_fn;
typedef pocket_store_fn pocket_word_store_fn;
typedef enum {
    POCKET_WORD_CORRECT, POCKET_WORD_WRONG, POCKET_WORD_FAMILIAR, POCKET_WORD_PARTIAL
} pocket_word_answer_t;

/* Original packed cards are accepted without translating historical failures
 * into partial answers. failed_round: 0 normal, 1 full reinforcement, 2 partial
 * repair in this task. Only the card flag persists across completed tasks. */
bool pocket_word_card_valid(uint32_t packed);
void pocket_word_init(pocket_word_state_t *s);
bool pocket_word_valid(const pocket_word_state_t *s);
void pocket_word_seal(pocket_word_state_t *s);
bool pocket_word_start(pocket_word_state_t *s, uint32_t day, pocket_word_read_fn read, void *context);
/* Candidate-only calendar admission for an existing task. Preserves old
   active words/tokens and new-word lesson fields; may fail on unreadable cards
   or checkpoint counter limits. Caller commits atomically or discards it.
   Also call after undo restores an older selection_day. */
bool pocket_word_refresh_due(pocket_word_state_t *s, uint32_t day,
                            pocket_word_read_fn read, void *context);
bool pocket_word_answer(pocket_word_state_t *s, pocket_word_answer_t answer,
                        pocket_word_read_fn read, void *context);
bool pocket_word_undo(pocket_word_state_t *s);
bool pocket_word_commit(pocket_word_state_t *live, pocket_word_state_t *next,
                        pocket_word_store_fn store, void *context);
uint16_t pocket_word_current_word(const pocket_word_state_t *s);
pocket_card_t pocket_word_current_card(const pocket_word_state_t *s);
bool pocket_word_current_partial(const pocket_word_state_t *s);
/* Distinct other words before this word's next token, capped at the target
 * gap. Zero is possible in a short tail; the UI must not claim a timed delay. */
uint16_t pocket_word_partial_gap(const pocket_word_state_t *s, uint16_t word);
uint16_t pocket_word_remaining(const pocket_word_state_t *s);
uint16_t pocket_word_unique_remaining(const pocket_word_state_t *s);
uint16_t pocket_word_new_remaining(const pocket_word_state_t *s);
uint16_t pocket_word_review_remaining(const pocket_word_state_t *s);
uint16_t pocket_word_group_size(const pocket_word_state_t *s);
uint16_t pocket_word_familiar_count(const pocket_word_state_t *s);
uint16_t pocket_word_first_known_count(const pocket_word_state_t *s);
