#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "pocket_deck.h"

#define POCKET_LESSON_SIZE 25u
#define POCKET_MAX_LEVEL 10u
#define POCKET_LESSON_COUNT ((POCKET_WORD_COUNT + POCKET_LESSON_SIZE - 1u) / POCKET_LESSON_SIZE)
#define POCKET_ACTIVE_MAX 50u
#define POCKET_QUEUE_MAX (POCKET_ACTIVE_MAX * 7u)
#define POCKET_NO_WORD UINT16_MAX
#define POCKET_MAGIC UINT32_C(0x584b4c50)
#define POCKET_VERSION 5u
#define POCKET_IMPORTED_KNOWN (UINT32_C(1) << 22)
#define POCKET_INITIAL_DAY 20742u
_Static_assert(POCKET_WORD_COUNT < UINT16_MAX, "Word IDs must fit below the sentinel");

typedef struct {
    uint32_t due_day;
    uint8_t level, learned, familiar, failed_round;
} pocket_card_t;
/* due16, level4, learned1, familiar1, imported-known1.
   The import flag marks PC completion without recorded errors, not proof of
   first-encounter recall. failed_round lives in the checkpoint. */
uint32_t pocket_pack_card(pocket_card_t card);
pocket_card_t pocket_unpack_card(uint32_t packed);
bool pocket_card_valid(uint32_t packed);
typedef struct { uint32_t packed; uint16_t word; uint8_t failed_round, used; } pocket_cached_t;
typedef struct { uint8_t slot, stage; } pocket_token_t;
typedef struct {
    uint32_t day, selection_day;
    uint16_t length, completed, skipped, new_total, review_total, lesson, first_known;
    uint16_t new_done, review_done, review_cursor, new_cursor, new_end, review_loaded, new_loaded;
    uint16_t total_familiar, total_first_known;
    pocket_cached_t active[POCKET_ACTIVE_MAX];
    pocket_token_t queue[POCKET_QUEUE_MAX];
} pocket_body_t;
typedef struct {
    uint32_t magic, version, deck_id, revision;
    pocket_body_t body, undo;
    uint32_t can_undo, changed_card, undo_card;
    uint16_t changed_word, undo_word;
    uint32_t checksum;
} pocket_state_t;
_Static_assert(sizeof(pocket_state_t) <= 3072, "Checkpoint must fit one journal transaction");
typedef enum { POCKET_CORRECT, POCKET_WRONG, POCKET_FAMILIAR } pocket_answer_t;
typedef bool (*pocket_read_fn)(uint16_t word, uint32_t *packed, void *context);
typedef bool (*pocket_store_fn)(const void *bytes, size_t size, uint16_t word,
                                uint32_t packed, void *context);
void pocket_init(pocket_state_t *s);
bool pocket_valid(const pocket_state_t *s);
void pocket_seal(pocket_state_t *s);
bool pocket_start(pocket_state_t *s, uint32_t day, pocket_read_fn read, void *context);
bool pocket_answer(pocket_state_t *s, pocket_answer_t answer, pocket_read_fn read, void *context);
bool pocket_undo(pocket_state_t *s);
bool pocket_commit(pocket_state_t *live, pocket_state_t *next, pocket_store_fn store, void *context);
uint16_t pocket_current_word(const pocket_state_t *s);
pocket_card_t pocket_current_card(const pocket_state_t *s);
uint16_t pocket_remaining(const pocket_state_t *s);
uint16_t pocket_unique_remaining(const pocket_state_t *s);
uint16_t pocket_new_remaining(const pocket_state_t *s);
uint16_t pocket_review_remaining(const pocket_state_t *s);
uint16_t pocket_group_size(const pocket_state_t *s);
uint16_t pocket_familiar_count(const pocket_state_t *s);
uint16_t pocket_first_known_count(const pocket_state_t *s);
