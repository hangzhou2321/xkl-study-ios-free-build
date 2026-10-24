#include "pocket_word_recording.h"
#include <string.h>

static uint32_t milliseconds(int64_t us) {
    return us < 0 || us / 1000 >= UINT32_MAX ? POCKET_LOG_UNKNOWN : (uint32_t)(us / 1000);
}
static pocket_event_t event(pocket_word_recording_t *r, const pocket_word_state_t *s,
                            pocket_event_kind_t kind, int64_t at) {
    pocket_event_t e = {0};
    e.kind = kind; e.day = s->body.day; e.task_day = s->body.selection_day;
    e.session = r->session; e.uptime_ms = milliseconds(at);
    e.word = POCKET_LOG_UNKNOWN; e.stage = POCKET_LOG_UNKNOWN;
    e.presentation = r->presented ? r->presentation : POCKET_LOG_UNKNOWN;
    e.reveal_ms = e.answer_ms = e.undo_revision = POCKET_LOG_UNKNOWN;
    e.before_revision = e.after_revision = s->revision;
    e.before_checksum = e.after_checksum = s->checksum;
    e.algorithm = POCKET_WORD_LOG_ALGORITHM;
    if (s->body.length) {
        const pocket_token_t *t = &s->body.queue[0];
        const pocket_cached_t *a = &s->body.active[t->slot];
        e.word = a->word; e.stage = t->stage;
        e.before_card = e.after_card = a->packed;
    }
    if (r->presented && r->revealed) {
        e.flags |= POCKET_EVENT_REVEALED;
        e.reveal_ms = milliseconds(r->revealed_at - r->presented_at);
        e.answer_ms = milliseconds(at - r->revealed_at);
    }
    if (e.uptime_ms == POCKET_LOG_UNKNOWN || !r->presented ||
        at < r->presented_at || (r->revealed &&
        (e.reveal_ms == POCKET_LOG_UNKNOWN || e.answer_ms == POCKET_LOG_UNKNOWN)))
        e.flags |= POCKET_EVENT_TIME_UNKNOWN;
    return e;
}
void pocket_word_recording_init(pocket_word_recording_t *r, pocket_log_t *log) {
    memset(r, 0, sizeof(*r)); r->log = log;
    r->presentation = POCKET_LOG_UNKNOWN;
}
bool pocket_word_recording_boot(pocket_word_recording_t *r, const pocket_word_state_t *s, int64_t at) {
    r->session = r->log->next_slot + 1;
    pocket_event_t e = event(r, s, POCKET_EVENT_BOOT, at);
    e.word = e.stage = POCKET_LOG_UNKNOWN; e.before_card = e.after_card = 0;
    return pocket_log_append(r->log, &e, NULL);
}
bool pocket_word_recording_present(pocket_word_recording_t *r, const pocket_word_state_t *s, int64_t at) {
    r->presented = r->revealed = false; r->presentation = POCKET_LOG_UNKNOWN;
    if (!s->body.length) { r->resumed_next = false; return true; }
    pocket_event_t e = event(r, s, POCKET_EVENT_PRESENT, at);
    e.flags = e.uptime_ms == POCKET_LOG_UNKNOWN ? POCKET_EVENT_TIME_UNKNOWN : 0;
    if (r->resumed_next) e.flags |= POCKET_EVENT_RESUME;
    uint32_t seq;
    if (!pocket_log_append(r->log, &e, &seq)) return false;
    r->presented = true; r->presentation = seq; r->presented_at = at;
    r->resumed_next = false;
    return true;
}
bool pocket_word_recording_reveal(pocket_word_recording_t *r, const pocket_word_state_t *s, int64_t at) {
    if (!r->presented || at < r->presented_at || !s->body.length) return false;
    if (r->revealed) return true; /* Meaning pagination is not another recall. */
    pocket_event_t e = event(r, s, POCKET_EVENT_REVEAL, at);
    e.flags |= POCKET_EVENT_REVEALED;
    e.reveal_ms = milliseconds(at - r->presented_at);
    if (e.reveal_ms == POCKET_LOG_UNKNOWN) e.flags |= POCKET_EVENT_TIME_UNKNOWN;
    if (!pocket_log_append(r->log, &e, NULL)) return false;
    r->revealed = true; r->revealed_at = at;
    return true;
}
bool pocket_word_recording_rest(pocket_word_recording_t *r, const pocket_word_state_t *s, int64_t at) {
    pocket_event_t e = event(r, s, POCKET_EVENT_REST, at);
    return pocket_log_append(r->log, &e, NULL);
}
bool pocket_word_recording_commit(pocket_word_recording_t *r, pocket_word_state_t *live,
    pocket_word_state_t *next, pocket_event_kind_t kind, int64_t at,
    pocket_word_read_fn read, pocket_word_store_fn store, void *context) {
    if (live->revision == UINT32_MAX || !pocket_word_valid(live) ||
        (kind != POCKET_EVENT_START && kind != POCKET_EVENT_CORRECT &&
         kind != POCKET_EVENT_WRONG && kind != POCKET_EVENT_PARTIAL && kind != POCKET_EVENT_FAMILIAR && kind != POCKET_EVENT_UNDO)) return false;
    if ((kind == POCKET_EVENT_CORRECT || kind == POCKET_EVENT_WRONG || kind == POCKET_EVENT_PARTIAL) &&
        (!r->presented || !r->revealed || at < r->revealed_at)) return false;
    if (kind == POCKET_EVENT_FAMILIAR && (!r->presented || at < r->presented_at)) return false;
    next->revision = live->revision + 1; pocket_word_seal(next);
    if (!pocket_word_valid(next)) return false;
    pocket_event_t e = event(r, live, kind, at);
    e.day = next->body.day; e.task_day = next->body.selection_day;
    e.after_revision = next->revision; e.after_checksum = next->checksum;
    if (next->changed_word == e.word) e.after_card = next->changed_card;
    if (kind == POCKET_EVENT_START) {
        e.presentation = e.word = e.stage = POCKET_LOG_UNKNOWN;
        e.before_card = e.after_card = 0;
        e.reveal_ms = e.answer_ms = POCKET_LOG_UNKNOWN;
        e.flags = live->body.length ? POCKET_EVENT_RESUME : 0;
        if (e.uptime_ms == POCKET_LOG_UNKNOWN) e.flags |= POCKET_EVENT_TIME_UNKNOWN;
    }
    if (kind == POCKET_EVENT_UNDO) {
        if (!live->can_undo || !read ||
            !read(live->undo_word, &e.before_card, context)) return false;
        e.word = live->undo_word; e.after_card = next->changed_card;
        e.presentation = e.stage = e.reveal_ms = e.answer_ms = POCKET_LOG_UNKNOWN;
        e.flags = POCKET_EVENT_TIME_UNKNOWN;
        if (!pocket_log_find_undo(r->log, e.word, e.before_card, &e.undo_revision)) return false;
        if (e.undo_revision == POCKET_LOG_UNKNOWN) e.flags |= POCKET_EVENT_UNDO_UNKNOWN;
    }
    if (!pocket_log_prepare(r->log, &e, NULL)) return false;
    if (!pocket_word_commit(live, next, store, context)) return false;
    if (!pocket_log_finalize(r->log, true)) return false;
    if (kind == POCKET_EVENT_START) r->resumed_next = (e.flags & POCKET_EVENT_RESUME) != 0;
    return true;
}

