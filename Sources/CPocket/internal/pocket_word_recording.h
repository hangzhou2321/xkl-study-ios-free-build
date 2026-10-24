#pragma once
#include "pocket_word_model.h"
#include "pocket_log.h"
#define POCKET_WORD_LOG_ALGORITHM 3u
/* Every event word field is a whole-word ID; core senses are content only. */
typedef struct {
    pocket_log_t *log;
    uint32_t session, presentation;
    int64_t presented_at, revealed_at;
    bool presented, revealed, resumed_next;
} pocket_word_recording_t;
void pocket_word_recording_init(pocket_word_recording_t *, pocket_log_t *);
bool pocket_word_recording_boot(pocket_word_recording_t *, const pocket_word_state_t *, int64_t at_us);
bool pocket_word_recording_present(pocket_word_recording_t *, const pocket_word_state_t *, int64_t at_us);
bool pocket_word_recording_reveal(pocket_word_recording_t *, const pocket_word_state_t *, int64_t at_us);
bool pocket_word_recording_rest(pocket_word_recording_t *, const pocket_word_state_t *, int64_t at_us);
/* A prepared event is durable before the checkpoint changes. On an uncertain
 * failure stop learning and reopen BOTH stores; never retry against stale RAM. */
bool pocket_word_recording_commit(pocket_word_recording_t *, pocket_word_state_t *live,
    pocket_word_state_t *next, pocket_event_kind_t, int64_t at_us,
    pocket_word_read_fn, pocket_word_store_fn, void *context);

