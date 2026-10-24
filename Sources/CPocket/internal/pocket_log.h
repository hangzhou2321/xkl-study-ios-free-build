#pragma once
#include "pocket_storage.h"
#include <stdint.h>
#include <stdbool.h>

#define POCKET_LOG_BYTES UINT32_C(0x200000)
#define POCKET_LOG_OFFSET UINT32_C(0x400000)
#define POCKET_LOG_HEADER_BYTES 4096u
#define POCKET_LOG_RECORD_BYTES 96u
#define POCKET_LOG_CAPACITY ((POCKET_LOG_BYTES - POCKET_LOG_HEADER_BYTES) / POCKET_LOG_RECORD_BYTES)
#define POCKET_LOG_ALGORITHM 1u
#define POCKET_LOG_UNKNOWN UINT32_MAX
#define POCKET_LOG_MAGIC UINT32_C(0x584b4c47)
#define POCKET_LOG_RECORD_MAGIC UINT32_C(0x584b4556)
#define POCKET_LOG_PREPARED UINT32_C(0x50524550)
#define POCKET_LOG_COMMITTED UINT32_C(0x434f4d54)
#define POCKET_LOG_ABORTED UINT32_C(0x41425254)
typedef enum {
    POCKET_EVENT_BOOT = 1, POCKET_EVENT_START, POCKET_EVENT_PRESENT,
    POCKET_EVENT_REVEAL, POCKET_EVENT_CORRECT, POCKET_EVENT_WRONG,
    POCKET_EVENT_FAMILIAR, POCKET_EVENT_UNDO, POCKET_EVENT_REST,
    POCKET_EVENT_PARTIAL = 10 /* Algorithm 3 only: whole-word meanings incomplete. */
} pocket_event_kind_t;
enum { POCKET_EVENT_REVEALED = 1u, POCKET_EVENT_RESUME = 2u,
       POCKET_EVENT_TIME_UNKNOWN = 4u, POCKET_EVENT_UNDO_UNKNOWN = 8u };
/* Disk record is 24 explicit little-endian uint32 words: magic, then the
 * following 20 fields, CRC(first 84 bytes), prepared marker, final marker.
 * PRESENT/REVEAL/REST describe requests, not proof of physical rendering/sleep.
 * Unknown durations/references use UINT32_MAX; session is the BOOT sequence. */
typedef struct {
    uint32_t sequence, kind, day, session, task_day, uptime_ms, word, stage;
    uint32_t before_card, after_card, before_revision, after_revision;
    uint32_t before_checksum, after_checksum, presentation, reveal_ms, answer_ms;
    uint32_t undo_revision, algorithm, flags;
} pocket_event_t;
typedef enum { POCKET_LOG_ERROR = -1, POCKET_LOG_EMPTY = 0, POCKET_LOG_READY = 1 } pocket_log_result_t;
typedef enum { POCKET_RECORD_UNUSED, POCKET_RECORD_TORN, POCKET_RECORD_PENDING,
               POCKET_RECORD_COMMITTED, POCKET_RECORD_ABORTED } pocket_record_status_t;
typedef struct {
    pocket_storage_io_t io;
    uint32_t deck_id, word_count, algorithm, stream[4], next_slot, pending_slot;
    pocket_event_t pending;
    bool ready, empty, failed, full;
} pocket_log_t;
pocket_log_result_t pocket_log_open(pocket_log_t *, pocket_storage_io_t,
    uint32_t deck_id, uint32_t word_count, uint32_t algorithm);
bool pocket_log_create(pocket_log_t *, const uint32_t stream[4]);
bool pocket_log_recover(pocket_log_t *, uint32_t revision, uint32_t checksum);
bool pocket_log_prepare(pocket_log_t *, const pocket_event_t *, uint32_t *sequence);
bool pocket_log_finalize(pocket_log_t *, bool committed);
bool pocket_log_append(pocket_log_t *, const pocket_event_t *, uint32_t *sequence);
bool pocket_log_read(pocket_log_t *, uint32_t slot, pocket_event_t *, pocket_record_status_t *);
/* before_card is the persistent value immediately before the undo action.
 * Match it against a prior committed CORRECT/FAMILIAR event's after_card and
 * return that event's after_revision. Missing references return true + UNKNOWN. */
bool pocket_log_find_undo(pocket_log_t *, uint32_t word, uint32_t before_card, uint32_t *revision);
/* No erase/rotation API: exported logs are cleared explicitly by the host
 * while the application is halted. Learning state is a separate partition. */
