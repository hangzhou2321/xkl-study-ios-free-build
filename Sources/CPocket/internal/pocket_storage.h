#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* A checkpoint and at most one card update form one committed transaction.
 * Card values are opaque packed uint32_t values. Unseen cards read as zero.
 * All calls run on one worker; no API is safe for concurrent callers. */
#define POCKET_STORAGE_PAGE 4096u
#define POCKET_STORAGE_CHECKPOINT_MAX 3072u
#define POCKET_STORAGE_JOURNAL_MAX 256u
#define POCKET_STORAGE_NO_CARD UINT32_MAX

typedef bool (*pocket_storage_read_fn)(void *, uint32_t, void *, size_t);
typedef bool (*pocket_storage_write_fn)(void *, uint32_t, const void *, size_t);
typedef bool (*pocket_storage_erase_fn)(void *, uint32_t, size_t);
typedef struct {
    void *context;
    uint32_t size;
    pocket_storage_read_fn read;
    pocket_storage_write_fn write;
    pocket_storage_erase_fn erase;
} pocket_storage_io_t;

typedef enum { POCKET_STORAGE_ERROR = -1, POCKET_STORAGE_EMPTY = 0,
               POCKET_STORAGE_READY = 1 } pocket_storage_result_t;
typedef struct { uint32_t id, value; } pocket_storage_entry_t;
typedef struct {
    pocket_storage_io_t io;
    uint32_t deck_id, card_count, checkpoint_size, bank_size;
    uint32_t base_size, checkpoint_offset, journal_offset, slot_count;
    uint32_t generation, sequence, bank, next_slot, entry_count;
    uint32_t cached_page;
    bool ready, empty, failed;
    pocket_storage_entry_t entries[POCKET_STORAGE_JOURNAL_MAX];
    uint8_t scratch[POCKET_STORAGE_PAGE];
} pocket_storage_t;

/* EMPTY is returned only for an entirely erased partition. Existing foreign,
 * incompatible or corrupt data is never silently reformatted. */
pocket_storage_result_t pocket_storage_open(pocket_storage_t *s,
    pocket_storage_io_t io, uint32_t deck_id, uint32_t card_count,
    size_t checkpoint_size, void *checkpoint);
bool pocket_storage_create(pocket_storage_t *s, const void *checkpoint);
bool pocket_storage_card(pocket_storage_t *s, uint32_t id, uint32_t *value);
bool pocket_storage_commit(pocket_storage_t *s, const void *checkpoint,
                           uint32_t changed_id, uint32_t value);
