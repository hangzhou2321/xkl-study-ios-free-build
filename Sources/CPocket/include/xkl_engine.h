#ifndef XKL_ENGINE_H
#define XKL_ENGINE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define XKL_WORD_COUNT 25644u
#define XKL_NO_WORD UINT32_MAX
#define XKL_DECK_VERSION "6509be5b320089b638219af4da5b42280e62c9960a6ba7cad67b225b8ec30e42"
typedef struct xkl_engine xkl_engine_t;
typedef struct {
    uint32_t word, day, lesson, new_remaining, review_remaining, total_remaining;
    uint32_t completed, stage, can_undo, revision, first_known, familiar;
    uint32_t log_records, log_capacity, partial_gap;
    uint8_t revealed, partial_pending, has_task;
    /* Admission cutoff can lag day in legacy unfinished-task snapshots. */
    uint32_t selection_day;
} xkl_info_t;

/* Policy v1 is an optional adapter above the unchanged algorithm-3 model.
 * Its decisions must be persisted alongside the snapshot by the caller. */
typedef struct {
    uint32_t version, word, day, answer_sequence, before_revision, after_revision;
    uint32_t first_sequence, qualified_recalls, distinct_gap, long_gap, removed;
} xkl_policy_result_t;
typedef struct {
    uint32_t version, plan, shortened_repeats, tail_removed, tail_deferred;
    uint32_t initial_learning_scheduled, initial_learning_repeats;
} xkl_exam_result_t;
typedef struct {
    uint32_t sequence, kind, day, word, stage, before_card, after_card;
    uint32_t before_revision, after_revision, undo_revision;
    uint32_t presentation, session, uptime_ms, reveal_ms, answer_ms, flags;
} xkl_event_info_t;

/* All calls require serialization by the caller. No source image is modified.
 * Seed accepts only the existing 2 MiB v8 state partition; stream16 is a newly
 * generated nonzero 16-byte log identity. Invalid/corrupt input returns NULL. */
xkl_engine_t *xkl_engine_seed(const uint8_t *image, size_t length,
                              const uint8_t *stream16);
/* Independent new collection using the unchanged whole-word scheduler.
 * Active IDs are 0..<active_count. Remaining storage slots are inert imported
 * completion sentinels, not user answers and never part of a learning task.
 * The caller must bind this snapshot to its own content hash and ID mapping. */
xkl_engine_t *xkl_engine_blank(uint32_t active_count, const uint8_t *stream16);
/* Restore preserves presentation state for local atomic-save rollback.
 * On app launch, clock discontinuity, or cross-device handoff call start before
 * learning: it logs a new session and hides the old answer. */
xkl_engine_t *xkl_engine_restore(const uint8_t *blob, size_t length);
void xkl_engine_free(xkl_engine_t *engine);
bool xkl_engine_start(xkl_engine_t *engine, uint32_t day, int64_t uptime_us);
bool xkl_engine_reveal(xkl_engine_t *engine, int64_t uptime_us);
/* 0=correct, 1=wrong, 2=familiar, 3=partial. Familiar is permitted before
 * reveal; other grades require reveal. Display the same whole-word meanings
 * for partial repair, then call answer(3) only when the user finishes reading. */
bool xkl_engine_answer(xkl_engine_t *engine, int answer, int64_t uptime_us);
bool xkl_engine_answer_conservative(xkl_engine_t *engine, int answer, int64_t uptime_us,
                                   bool enabled, uint32_t first_sequence, xkl_policy_result_t *result);
/* Question-only experiment: plan 0 keeps the original algorithm, plan 1 is
 * allowed only for WRONG and retains stages 1/4/7, plan 2 is an existing short
 * plan and may end a correct short tail at tomorrow instead of adjacent taps.
 * Correct-only plans 3 and 4 start three (stages 1/4/7) or seven reinforcement
 * checks for a virgin stage-0 question. They log the real CORRECT answer, do
 * not mark it first-known, and must not increase the host's failure count.
 * Only explicit FAMILIAR skips newly studied questions permanently.
 * The host durably tracks within-task failures and never selects plan 1 twice
 * for the same question/task. The vocabulary entry points always use plan 0. */
bool xkl_engine_answer_exam(xkl_engine_t *engine, int answer, int64_t uptime_us,
    bool conservative_enabled, uint32_t first_sequence, uint32_t exam_plan,
    xkl_policy_result_t *policy, xkl_exam_result_t *exam);
uint32_t xkl_engine_current_repeats(const xkl_engine_t *engine);
/* A virgin stage-0 question, with no prior learning or reinforcement state. */
bool xkl_engine_current_is_new(const xkl_engine_t *engine);
bool xkl_engine_event(const xkl_engine_t *engine, uint32_t zero_based_index, xkl_event_info_t *event);
bool xkl_engine_stream(const xkl_engine_t *engine, uint8_t *stream16);
/* Rotate only after the caller durably archives the old snapshot. No card,
 * queue, revision, reveal state or undo opportunity changes. Global event IDs
 * stay monotonic; synthetic carry records are omitted by xkl_engine_event. */
bool xkl_engine_rotate_log(xkl_engine_t *engine, uint32_t policy_first_sequence);
uint32_t xkl_engine_log_base(const xkl_engine_t *engine);
uint32_t xkl_engine_volume_records(const xkl_engine_t *engine);
bool xkl_engine_undo(xkl_engine_t *engine, int64_t uptime_us);
size_t xkl_engine_snapshot_size(const xkl_engine_t *engine);
/* Compact explicit little-endian format + CRC32, never a raw C structure.
 * Returns bytes written, or zero. Caller must persist atomically before UI
 * advancement; restore the previous snapshot if persistence fails. */
size_t xkl_engine_snapshot(const xkl_engine_t *engine, uint8_t *out, size_t capacity);
bool xkl_engine_info(const xkl_engine_t *engine, xkl_info_t *info);
/* Original packed card, unchanged; UINT32_MAX for invalid engine/word. */
uint32_t xkl_engine_card(const xkl_engine_t *engine, uint32_t word);
/* Original binary log header + occupied records; trailing erased Flash bytes
 * are omitted. A full export parser can pad with 0xff to 2 MiB. */
size_t xkl_engine_log_size(const xkl_engine_t *engine);
size_t xkl_engine_log(const xkl_engine_t *engine, uint8_t *out, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
