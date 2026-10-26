#include "include/xkl_engine.h"
#include "internal/pocket_word_recording.h"
#include "internal/pocket_review_intervals.h"
#include <stdlib.h>
#include <string.h>

uint16_t xkl_word_review_interval_days(uint32_t level) {
    return pocket_review_interval_days(level);
}

#define SNAP_MAGIC UINT32_C(0x534c4b58)
#define SNAP_VERSION 1u
#define SNAP_HEADER 96u
#define CHECKPOINT_BYTES 2316u
#define STATE_IMAGE_BYTES UINT32_C(0x200000)
#define SNAP_FIXED (SNAP_HEADER + CHECKPOINT_BYTES + XKL_WORD_COUNT * 4u + 4u)
#define PROOF_MAX (POCKET_ACTIVE_MAX * 2u)
typedef struct {
    uint32_t word;
    uint16_t seen[7];
    uint8_t distinct, recalls, anchored, long_gap;
} proof_t;
_Static_assert(sizeof(pocket_word_state_t) == CHECKPOINT_BYTES, "v8 checkpoint ABI changed");
_Static_assert(sizeof(pocket_body_t) == 1140u, "v8 body ABI changed");
_Static_assert(offsetof(pocket_state_t, checksum) == 2312u, "v8 CRC offset changed");

struct xkl_engine {
    pocket_word_state_t state;
    uint32_t cards[XKL_WORD_COUNT];
    uint8_t *log_bytes;
    pocket_log_t log;
    pocket_word_recording_t recording;
    int64_t last_at;
    bool booted;
    bool volume_mode;
    uint32_t sequence_offset, carry_count, carry_presentation, carry_session, carry_undo;
    uint32_t proof_day, proof_first, proof_count;
    proof_t proofs[PROOF_MAX];
};
typedef struct { const uint8_t *bytes; size_t length; } seed_io_t;
static uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void put32(uint8_t *p, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (i * 8));
}
static uint64_t get64(const uint8_t *p) { return get32(p) | (uint64_t)get32(p + 4) << 32; }
static void put64(uint8_t *p, uint64_t value) { put32(p, (uint32_t)value); put32(p + 4, (uint32_t)(value >> 32)); }
static uint32_t crc32(const uint8_t *p, size_t n) {
    uint32_t c = UINT32_MAX;
    while (n--) { c ^= *p++; for (unsigned i = 0; i < 8; ++i) c = (c >> 1) ^ (UINT32_C(0xedb88320) & (0u - (c & 1u))); }
    return ~c;
}
static bool little_endian(void) { const uint16_t x = 1; return *(const uint8_t *)&x == 1; }
static bool seed_read(void *ctx, uint32_t at, void *out, size_t n) {
    const seed_io_t *s = ctx;
    if (at > s->length || n > s->length - at) return false;
    memcpy(out, s->bytes + at, n); return true;
}
static bool seed_write(void *ctx, uint32_t at, const void *p, size_t n) { (void)ctx; (void)at; (void)p; (void)n; return false; }
static bool seed_erase(void *ctx, uint32_t at, size_t n) { (void)ctx; (void)at; (void)n; return false; }
static bool log_read(void *ctx, uint32_t at, void *out, size_t n) {
    xkl_engine_t *e = ctx;
    if (at > POCKET_LOG_BYTES || n > POCKET_LOG_BYTES - at) return false;
    memcpy(out, e->log_bytes + at, n); return true;
}
static bool log_write(void *ctx, uint32_t at, const void *data, size_t n) {
    xkl_engine_t *e = ctx; const uint8_t *p = data;
    if (at > POCKET_LOG_BYTES || n > POCKET_LOG_BYTES - at) return false;
    for (size_t i = 0; i < n; ++i) if ((e->log_bytes[at + i] & p[i]) != p[i]) return false;
    memcpy(e->log_bytes + at, p, n); return true;
}
static pocket_storage_io_t log_io(xkl_engine_t *e) {
    return (pocket_storage_io_t){e, POCKET_LOG_BYTES, log_read, log_write, NULL};
}
static bool card_read(uint16_t word, uint32_t *value, void *ctx) {
    xkl_engine_t *e = ctx;
    if (word >= XKL_WORD_COUNT || !value) return false;
    *value = e->cards[word]; return true;
}
static bool state_store(const void *p, size_t n, uint16_t word, uint32_t value, void *ctx) {
    xkl_engine_t *e = ctx;
    if (n != sizeof(e->state) || !pocket_word_valid(p) ||
        (word != POCKET_NO_WORD && (word >= XKL_WORD_COUNT || !pocket_word_card_valid(value)))) return false;
    if (word != POCKET_NO_WORD) e->cards[word] = value;
    return true;
}
static xkl_engine_t *allocate_engine(void) {
    if (!little_endian()) return NULL; /* Original checkpoint CRC is the v8 LE ABI. */
    xkl_engine_t *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->log_bytes = malloc(POCKET_LOG_BYTES);
    if (!e->log_bytes) { free(e); return NULL; }
    memset(e->log_bytes, 255, POCKET_LOG_BYTES);
    e->last_at = 0;
    return e;
}
void xkl_engine_free(xkl_engine_t *e) { if (e) { free(e->log_bytes); free(e); } }
static bool state_consistent(const xkl_engine_t *e) {
    if (!pocket_word_valid(&e->state)) return false;
    for (uint32_t i = 0; i < XKL_WORD_COUNT; ++i) if (!pocket_word_card_valid(e->cards[i])) return false;
    for (unsigned i = 0; i < POCKET_ACTIVE_MAX; ++i) {
        const pocket_cached_t *a = &e->state.body.active[i];
        if (a->used && e->cards[a->word] != a->packed) return false;
    }
    if (e->state.changed_word != POCKET_NO_WORD && e->cards[e->state.changed_word] != e->state.changed_card) return false;
    return true;
}
xkl_engine_t *xkl_engine_seed(const uint8_t *image, size_t length, const uint8_t *stream16) {
    if (!image || length != STATE_IMAGE_BYTES || !stream16) return NULL;
    uint32_t stream[4];
    for (unsigned i = 0; i < 4; ++i) stream[i] = get32(stream16 + i * 4);
    if (!(stream[0] | stream[1] | stream[2] | stream[3])) return NULL;
    xkl_engine_t *e = allocate_engine();
    if (!e) return NULL;
    seed_io_t seed = {image, length}; pocket_storage_t store;
    pocket_storage_io_t io = {&seed, (uint32_t)length, seed_read, seed_write, seed_erase};
    if (pocket_storage_open(&store, io, POCKET_WORD_DECK_ID, XKL_WORD_COUNT, sizeof(e->state), &e->state) != POCKET_STORAGE_READY) goto error;
    for (uint32_t i = 0; i < XKL_WORD_COUNT; ++i) if (!pocket_storage_card(&store, i, &e->cards[i])) goto error;
    if (!state_consistent(e) || pocket_log_open(&e->log, log_io(e), POCKET_WORD_DECK_ID, XKL_WORD_COUNT, POCKET_WORD_LOG_ALGORITHM) != POCKET_LOG_EMPTY || !pocket_log_create(&e->log, stream)) goto error;
    pocket_word_recording_init(&e->recording, &e->log);
    return e;
error:
    xkl_engine_free(e); return NULL;
}

xkl_engine_t *xkl_engine_blank(uint32_t active_count, const uint8_t *stream16) {
    if (!active_count || active_count > XKL_WORD_COUNT || !stream16) return NULL;
    uint32_t stream[4];
    for (unsigned i = 0; i < 4; ++i) stream[i] = get32(stream16 + i * 4);
    if (!(stream[0] | stream[1] | stream[2] | stream[3])) return NULL;
    xkl_engine_t *e = allocate_engine();
    if (!e) return NULL;
    pocket_word_init(&e->state);
    pocket_card_t inert = {.due_day = UINT32_MAX, .learned = 1};
    const uint32_t excluded = pocket_pack_card(inert) | POCKET_IMPORTED_KNOWN;
    for (uint32_t i = active_count; i < XKL_WORD_COUNT; ++i) e->cards[i] = excluded;
    if (!state_consistent(e) ||
        pocket_log_open(&e->log, log_io(e), POCKET_WORD_DECK_ID, XKL_WORD_COUNT,
                        POCKET_WORD_LOG_ALGORITHM) != POCKET_LOG_EMPTY ||
        !pocket_log_create(&e->log, stream)) {
        xkl_engine_free(e); return NULL;
    }
    pocket_word_recording_init(&e->recording, &e->log);
    return e;
}

xkl_engine_t *xkl_engine_import_cards(uint32_t active_count,
    const uint32_t *packed_cards, uint32_t day, uint32_t pending_word,
    const uint8_t *stream16) {
    if (!active_count || active_count > XKL_WORD_COUNT || !packed_cards ||
        day < 18000u || day > 50000u ||
        (pending_word != XKL_NO_WORD && pending_word >= active_count)) return NULL;
    for (uint32_t i = 0; i < active_count; ++i)
        if (!pocket_word_card_valid(packed_cards[i])) return NULL;
    if (pending_word != XKL_NO_WORD) {
        pocket_card_t pending = pocket_unpack_card(packed_cards[pending_word]);
        if (pending.familiar || (pending.learned && !pending.level)) return NULL;
    }
    xkl_engine_t *e = xkl_engine_blank(active_count, stream16);
    if (!e) return NULL;
    memcpy(e->cards, packed_cards, active_count * sizeof(*packed_cards));
    pocket_word_body_t *b = &e->state.body;
    b->day = b->selection_day = day;
    if (pending_word != XKL_NO_WORD) {
        /* This is an explicitly imported checkpoint, not a synthetic answer.
         * A single outstanding presentation is finished before the ordinary
         * task builder admits the remaining due cards and next lesson. */
        pocket_card_t pending = pocket_unpack_card(packed_cards[pending_word]);
        b->active[0] = (pocket_word_cached_t){packed_cards[pending_word],
            (uint16_t)pending_word,
            (packed_cards[pending_word] & POCKET_WORD_PARTIAL_PENDING) ? 2u : 0u, 1};
        b->queue[0] = (pocket_token_t){0, 0};
        b->length = 1;
        if (pending.learned) {
            b->review_total = b->review_loaded = 1;
            b->review_cursor = (uint16_t)(pending_word + 1u);
        } else {
            b->new_total = b->new_loaded = 1;
            b->lesson = (uint16_t)(pending_word / POCKET_LESSON_SIZE + 1u);
            b->new_cursor = b->new_end = (uint16_t)(pending_word + 1u);
        }
    }
    pocket_word_seal(&e->state);
    if (!state_consistent(e)) { xkl_engine_free(e); return NULL; }
    return e;
}

/* Each checkpoint scalar has an explicit wire width; no host padding enters
 * the snapshot. Layout matches v8 so its original CRC is retained verbatim. */
typedef struct { uint8_t *out; const uint8_t *in; size_t at; } codec_t;
static void code32(codec_t *c, uint32_t *value) {
    if (c->out) put32(c->out + c->at, *value); else *value = get32(c->in + c->at);
    c->at += 4;
}
static void code16(codec_t *c, uint16_t *value) {
    if (c->out) { c->out[c->at] = (uint8_t)*value; c->out[c->at + 1] = (uint8_t)(*value >> 8); }
    else *value = (uint16_t)((uint16_t)c->in[c->at] | (uint16_t)c->in[c->at + 1] << 8);
    c->at += 2;
}
static void code8(codec_t *c, uint8_t *value) { if (c->out) c->out[c->at] = *value; else *value = c->in[c->at]; ++c->at; }
static void body_codec(codec_t *c, pocket_body_t *b) {
    code32(c, &b->day); code32(c, &b->selection_day);
    code16(c, &b->length); code16(c, &b->completed); code16(c, &b->skipped);
    code16(c, &b->new_total); code16(c, &b->review_total); code16(c, &b->lesson); code16(c, &b->first_known);
    code16(c, &b->new_done); code16(c, &b->review_done); code16(c, &b->review_cursor); code16(c, &b->new_cursor);
    code16(c, &b->new_end); code16(c, &b->review_loaded); code16(c, &b->new_loaded);
    code16(c, &b->total_familiar); code16(c, &b->total_first_known);
    for (unsigned i = 0; i < POCKET_ACTIVE_MAX; ++i) {
        code32(c, &b->active[i].packed); code16(c, &b->active[i].word);
        code8(c, &b->active[i].failed_round); code8(c, &b->active[i].used);
    }
    for (unsigned i = 0; i < POCKET_QUEUE_MAX; ++i) { code8(c, &b->queue[i].slot); code8(c, &b->queue[i].stage); }
}
static void checkpoint_codec(codec_t *c, pocket_state_t *s) {
    code32(c, &s->magic); code32(c, &s->version); code32(c, &s->deck_id); code32(c, &s->revision);
    body_codec(c, &s->body); body_codec(c, &s->undo);
    code32(c, &s->can_undo); code32(c, &s->changed_card); code32(c, &s->undo_card);
    code16(c, &s->changed_word); code16(c, &s->undo_word); code32(c, &s->checksum);
}
static bool live_ready(const xkl_engine_t *e) {
    return e && e->log.ready && !e->log.failed && e->log.pending_slot == POCKET_LOG_UNKNOWN;
}
static bool room(const xkl_engine_t *e, uint32_t n) {
    return live_ready(e) && n<=POCKET_LOG_CAPACITY-e->log.next_slot &&
        e->sequence_offset<=UINT32_MAX-e->log.next_slot-n-1u;
}
static bool clock_ok(const xkl_engine_t *e, int64_t at) { return e && e->booted && at >= e->last_at && at >= 0; }
static uint32_t global_sequence(const xkl_engine_t *e, uint32_t local) { return local == UINT32_MAX ? local : local + e->sequence_offset; }
static uint32_t global_presentation(const xkl_engine_t *e, uint32_t local) {
    return e->volume_mode && local == 2u ? e->carry_presentation : global_sequence(e,local);
}
bool xkl_engine_start(xkl_engine_t *e, uint32_t day, int64_t at) {
    if (!room(e, 3) || day < 18000 || day > 50000 || at < 0 || e->state.revision == UINT32_MAX) return false;
    pocket_word_state_t next = e->state;
    if (!pocket_word_start(&next, day, card_read, e)) return false;
    pocket_word_recording_init(&e->recording, &e->log);
    if (!pocket_word_recording_boot(&e->recording, &e->state, at) ||
        !pocket_word_recording_commit(&e->recording, &e->state, &next, POCKET_EVENT_START, at, card_read, state_store, e) ||
        !pocket_word_recording_present(&e->recording, &e->state, at)) return false;
    e->booted = true; e->last_at = at; return true;
}
bool xkl_engine_reveal(xkl_engine_t *e, int64_t at) {
    if (!clock_ok(e, at) || !room(e, e->recording.revealed ? 0 : 1)) return false;
    if (!pocket_word_recording_reveal(&e->recording, &e->state, at)) return false;
    e->last_at = at; return true;
}
/* Count only actual graded encounters since activation, within this calendar
 * day. Repeated views, familiar skips, adjacent repeats and undone evidence do
 * not earn recall credit. Fixed seven-element storage caps distinct gaps. */
static bool proof_for(xkl_engine_t *e, uint32_t word, uint32_t first, proof_t *p) {
    memset(p,0,sizeof(*p));p->word=word;
    uint32_t day=e->state.body.day;
    if (!first || first > e->sequence_offset + e->log.next_slot + 1u) return false;
    if (e->volume_mode && e->proof_day==day && e->proof_first==first)
        for (unsigned i=0;i<e->proof_count;++i) if (e->proofs[i].word==word) *p=e->proofs[i];
    uint32_t begin=first>e->sequence_offset ? first-e->sequence_offset-1u : 0;
    if (begin<e->carry_count) begin=e->carry_count;
    for (uint32_t i = begin; i < e->log.next_slot; ++i) {
        pocket_event_t event; pocket_record_status_t status;
        if (!pocket_log_read(&e->log, i, &event, &status) || status != POCKET_RECORD_COMMITTED) return false;
        if (event.day != day || event.kind == POCKET_EVENT_UNDO) {
            p->distinct=p->recalls=p->anchored=p->long_gap=0;continue;
        }
        bool graded = event.kind == POCKET_EVENT_CORRECT || event.kind == POCKET_EVENT_WRONG || event.kind == POCKET_EVENT_PARTIAL;
        if (!graded || event.word >= XKL_WORD_COUNT) continue;
        if (event.word != word) {
            bool exists = false;
            for (unsigned n=0;n<p->distinct;++n) if(p->seen[n]==event.word) exists=true;
            if(!exists && p->distinct<7u) p->seen[p->distinct++]=(uint16_t)event.word;
        } else {
            if(event.kind!=POCKET_EVENT_CORRECT) { p->recalls=0;p->long_gap=0; }
            else if(p->anchored && p->distinct>=3u) {
                if(p->recalls<3u) ++p->recalls;
                if(p->distinct>=7u) p->long_gap=1;
            }
            p->anchored=1;p->distinct=0;
        }
    }
    return true;
}
static bool conservative_proof(xkl_engine_t *e, uint32_t first, xkl_policy_result_t *out) {
    proof_t p;if(!proof_for(e,pocket_word_current_word(&e->state),first,&p)) return false;
    out->distinct_gap=p.distinct;
    if(p.anchored && p.distinct>=3u) {
        if(p.recalls<3u) ++p.recalls;
        if(p.distinct>=7u) p.long_gap=1;
    }
    out->qualified_recalls=p.recalls;out->long_gap=p.long_gap;
    return true;
}
static unsigned remove_future_repeats(pocket_word_state_t *s) {
    pocket_word_body_t *b = &s->body; unsigned old = b->length, kept = 1;
    const unsigned slot = b->queue[0].slot;
    for (unsigned i = 1; i < old; ++i) if (b->queue[i].slot != slot) b->queue[kept++] = b->queue[i];
    memset(b->queue + kept, 0, (old - kept) * sizeof(b->queue[0]));
    b->length = (uint16_t)kept;
    return old - kept;
}
bool xkl_engine_current_is_new(const xkl_engine_t *e) {
    if (!live_ready(e) || !e->state.body.length) return false;
    const pocket_token_t *t = &e->state.body.queue[0];
    const pocket_word_cached_t *a = &e->state.body.active[t->slot];
    return t->stage == 0 && a->failed_round == 0 && a->packed == 0;
}
static bool answer_with_plan(xkl_engine_t *e, int answer, int64_t at,
    bool enabled, uint32_t first_sequence, uint32_t exam_plan,
    xkl_policy_result_t *result, xkl_exam_result_t *exam) {
    xkl_policy_result_t decision = {0};
    xkl_exam_result_t exam_decision = {.version = 1, .plan = exam_plan};
    if (result) memset(result, 0, sizeof(*result));
    if (exam) memset(exam, 0, sizeof(*exam));
    if (exam_plan > 4u || (exam_plan == 1u && answer != POCKET_WORD_WRONG) ||
        (exam_plan >= 3u && answer != POCKET_WORD_CORRECT)) return false;
    if (!clock_ok(e, at) || !room(e, 2) || answer < 0 || answer > 3 || !e->recording.presented ||
        (answer != POCKET_WORD_FAMILIAR && !e->recording.revealed) || e->state.revision == UINT32_MAX) return false;
    if (exam_plan >= 3u && !xkl_engine_current_is_new(e)) return false;
    pocket_word_state_t next = e->state;
    decision.version = 1; decision.word = pocket_word_current_word(&e->state); decision.day = e->state.body.day;
    decision.first_sequence = first_sequence; decision.before_revision = e->state.revision;
    decision.answer_sequence = global_sequence(e,e->log.next_slot+1u);
    const unsigned slot = e->state.body.queue[0].slot;
    if (enabled && answer == POCKET_WORD_CORRECT && e->state.body.active[slot].failed_round == 1 &&
        e->state.body.queue[0].stage > 0) {
        if (!conservative_proof(e, first_sequence, &decision)) return false;
        if (decision.qualified_recalls >= 3u && decision.long_gap && decision.distinct_gap >= 3u)
            decision.removed = remove_future_repeats(&next);
    }
    if (exam_plan == 2u && answer == POCKET_WORD_CORRECT &&
        next.body.active[slot].failed_round == 1) {
        bool other = false;
        for (unsigned i = 0; i < next.body.length; ++i)
            if (next.body.queue[i].slot != slot) other = true;
        if (!other) {
            exam_decision.tail_removed = remove_future_repeats(&next);
            exam_decision.tail_deferred = exam_decision.tail_removed != 0;
        }
    }
    /* Reuse the unchanged model's reinforcement construction for new
     * questions. This is a scheduling command, not the observed answer:
     * committed event kinds and the caller's error count retain CORRECT. */
    pocket_word_answer_t schedule_answer = exam_plan >= 3u ?
        POCKET_WORD_WRONG : (pocket_word_answer_t)answer;
    if (!pocket_word_answer(&next, schedule_answer, card_read, e)) return false;
    if (exam_plan == 1u || exam_plan == 3u) {
        unsigned kept = 0, old = next.body.length;
        for (unsigned i = 0; i < old; ++i) {
            pocket_token_t t = next.body.queue[i];
            if (t.slot != slot || t.stage == 1u || t.stage == 4u || t.stage == 7u)
                next.body.queue[kept++] = t;
        }
        memset(next.body.queue + kept, 0, (old - kept) * sizeof(next.body.queue[0]));
        next.body.length = (uint16_t)kept;
        exam_decision.shortened_repeats = old - kept;
    }
    if (exam_plan >= 3u) {
        exam_decision.initial_learning_scheduled = 1;
        exam_decision.initial_learning_repeats = exam_plan == 3u ? 3u : 7u;
    }
    static const pocket_event_kind_t kinds[] = {POCKET_EVENT_CORRECT, POCKET_EVENT_WRONG, POCKET_EVENT_FAMILIAR, POCKET_EVENT_PARTIAL};
    if (!pocket_word_recording_commit(&e->recording, &e->state, &next, kinds[answer], at, card_read, state_store, e) ||
        !pocket_word_recording_present(&e->recording, &e->state, at)) return false;
    e->last_at = at; decision.after_revision = e->state.revision;
    if (result) *result = decision;
    if (exam) *exam = exam_decision;
    return true;
}
bool xkl_engine_answer_conservative(xkl_engine_t *e, int answer, int64_t at,
                                   bool enabled, uint32_t first, xkl_policy_result_t *result) {
    return answer_with_plan(e, answer, at, enabled, first, 0, result, NULL);
}
bool xkl_engine_answer_exam(xkl_engine_t *e, int answer, int64_t at,
    bool enabled, uint32_t first, uint32_t plan, xkl_policy_result_t *policy, xkl_exam_result_t *exam) {
    return answer_with_plan(e, answer, at, enabled, first, plan, policy, exam);
}
uint32_t xkl_engine_current_repeats(const xkl_engine_t *e) {
    if (!live_ready(e) || !e->state.body.length) return 0;
    unsigned slot = e->state.body.queue[0].slot, count = 0;
    for (unsigned i = 0; i < e->state.body.length; ++i)
        if (e->state.body.queue[i].slot == slot && e->state.body.queue[i].stage > 0) ++count;
    return count;
}
bool xkl_engine_answer(xkl_engine_t *e, int answer, int64_t at) {
    return xkl_engine_answer_conservative(e, answer, at, false, 0, NULL);
}
bool xkl_engine_event(const xkl_engine_t *engine, uint32_t index, xkl_event_info_t *out) {
    if (!live_ready(engine) || !out || index < engine->sequence_offset+engine->carry_count ||
        index >= engine->sequence_offset+engine->log.next_slot) return false;
    index-=engine->sequence_offset;
    pocket_event_t e; pocket_record_status_t status;
    if (!pocket_log_read((pocket_log_t *)&engine->log, index, &e, &status) || status != POCKET_RECORD_COMMITTED) return false;
    *out = (xkl_event_info_t){global_sequence(engine,e.sequence),e.kind,e.day,e.word,e.stage,e.before_card,e.after_card,
                            e.before_revision,e.after_revision,e.undo_revision,
                            global_presentation(engine,e.presentation),
                            engine->volume_mode && e.session==1u ? engine->carry_session : global_sequence(engine,e.session),
                            e.uptime_ms,e.reveal_ms,e.answer_ms,e.flags};
    return true;
}
bool xkl_engine_stream(const xkl_engine_t *engine, uint8_t *out) {
    if (!live_ready(engine) || !out) return false;
    for (unsigned i = 0; i < 4; ++i) put32(out + i * 4, engine->log.stream[i]);
    return true;
}
bool xkl_engine_undo(xkl_engine_t *e, int64_t at) {
    if (!clock_ok(e, at) || !room(e, 2) || e->state.revision == UINT32_MAX) return false;
    pocket_word_state_t next = e->state;
    if (!pocket_word_undo(&next) ||
        !pocket_word_refresh_due(&next, next.body.day, card_read, e) ||
        !pocket_word_recording_commit(&e->recording, &e->state, &next, POCKET_EVENT_UNDO, at, card_read, state_store, e)) return false;
    uint8_t *record=e->log_bytes+POCKET_LOG_HEADER_BYTES+(e->log.next_slot-1u)*POCKET_LOG_RECORD_BYTES;
    if(e->volume_mode && get32(record+72)==UINT32_MAX && e->carry_undo!=UINT32_MAX) {
        put32(record+72,e->carry_undo);put32(record+80,get32(record+80)&~POCKET_EVENT_UNDO_UNKNOWN);
        put32(record+84,crc32(record,84));
    }
    if(!pocket_word_recording_present(&e->recording,&e->state,at)) return false;
    e->last_at = at; return true;
}
size_t xkl_engine_log_size(const xkl_engine_t *e) { return live_ready(e) ? POCKET_LOG_HEADER_BYTES + (size_t)e->log.next_slot * POCKET_LOG_RECORD_BYTES : 0; }
size_t xkl_engine_log(const xkl_engine_t *e, uint8_t *out, size_t capacity) {
    size_t n = xkl_engine_log_size(e); if (!n || !out || capacity < n) return 0;
    memcpy(out, e->log_bytes, n); return n;
}
static size_t context_size(const xkl_engine_t *e) { return e->volume_mode ? 12u+22u*e->proof_count : 0; }
size_t xkl_engine_snapshot_size(const xkl_engine_t *e) { size_t n = xkl_engine_log_size(e); return n ? SNAP_FIXED+n+context_size(e) : 0; }
size_t xkl_engine_snapshot(const xkl_engine_t *e, uint8_t *out, size_t capacity) {
    size_t n = xkl_engine_snapshot_size(e), log_n = xkl_engine_log_size(e);
    if (!n || !out || capacity < n || !state_consistent(e)) return 0;
    memset(out, 0, SNAP_HEADER);
    put32(out, SNAP_MAGIC); put32(out + 4, e->volume_mode ? 2u : SNAP_VERSION); put32(out + 8, SNAP_HEADER);
    put32(out + 12, POCKET_WORD_DECK_ID); put32(out + 16, POCKET_WORD_LOG_ALGORITHM);
    put32(out + 20, XKL_WORD_COUNT); put32(out + 24, CHECKPOINT_BYTES); put32(out + 28, (uint32_t)log_n);
    put32(out + 32, (uint32_t)n);
    uint32_t flags = (e->booted ? 1u : 0u) | (e->recording.presented ? 2u : 0u) | (e->recording.revealed ? 4u : 0u) | (e->recording.resumed_next ? 8u : 0u);
    put32(out + 36, flags); put32(out + 40, e->recording.session); put32(out + 44, e->recording.presentation);
    put64(out + 48, (uint64_t)e->recording.presented_at); put64(out + 56, (uint64_t)e->recording.revealed_at);
    put64(out + 64, (uint64_t)e->last_at);
    if(e->volume_mode) {
        put32(out+72,e->sequence_offset);put32(out+76,e->carry_count);
        put32(out+80,e->carry_presentation);put32(out+84,e->carry_session);
        put32(out+88,e->carry_undo);put32(out+92,(uint32_t)context_size(e));
    }
    pocket_state_t copy = e->state; codec_t c = {out + SNAP_HEADER, NULL, 0}; checkpoint_codec(&c, &copy);
    size_t at = SNAP_HEADER + c.at;
    for (uint32_t i = 0; i < XKL_WORD_COUNT; ++i, at += 4) put32(out + at, e->cards[i]);
    memcpy(out + at, e->log_bytes, log_n);
    at+=log_n;
    if(e->volume_mode) {
        put32(out+at,e->proof_day);put32(out+at+4,e->proof_first);put32(out+at+8,e->proof_count);at+=12;
        for(unsigned i=0;i<e->proof_count;++i) {
            proof_t p=e->proofs[i];codec_t pc={out+at,NULL,0};
            code32(&pc,&p.word);for(unsigned j=0;j<7;++j) code16(&pc,&p.seen[j]);
            code8(&pc,&p.distinct);code8(&pc,&p.recalls);code8(&pc,&p.anchored);code8(&pc,&p.long_gap);at+=pc.at;
        }
    }
    put32(out + n - 4, crc32(out, n - 4)); return n;
}
static bool log_state_consistent(xkl_engine_t *e) {
    if (e->log.pending_slot != POCKET_LOG_UNKNOWN) return false;
    pocket_event_t last = {0}; bool have = false;
    uint32_t last_boot = 0, last_presentation = POCKET_LOG_UNKNOWN;
    bool last_revealed = false;
    for (uint32_t i = 0; i < e->log.next_slot; ++i) {
        pocket_event_t event; pocket_record_status_t status;
        if (!pocket_log_read(&e->log, i, &event, &status) || status != POCKET_RECORD_COMMITTED) return false;
        if (have && (event.before_revision != last.after_revision || event.before_checksum != last.after_checksum)) return false;
        if (event.before_revision > event.after_revision || event.after_revision - event.before_revision > 1u) return false;
        if ((event.word != POCKET_LOG_UNKNOWN && (!pocket_word_card_valid(event.before_card) || !pocket_word_card_valid(event.after_card)))) return false;
        if (event.kind == POCKET_EVENT_BOOT) { last_boot = event.sequence; last_presentation = POCKET_LOG_UNKNOWN; last_revealed = false; }
        if (event.session != last_boot || !last_boot) return false;
        if (event.kind == POCKET_EVENT_PRESENT) { last_presentation = event.sequence; last_revealed = false; }
        if (event.kind == POCKET_EVENT_REVEAL) {
            if (event.presentation != last_presentation || last_presentation == POCKET_LOG_UNKNOWN) return false;
            last_revealed = true;
        }
        if (event.kind == POCKET_EVENT_START || event.kind == POCKET_EVENT_CORRECT || event.kind == POCKET_EVENT_WRONG ||
            event.kind == POCKET_EVENT_FAMILIAR || event.kind == POCKET_EVENT_PARTIAL || event.kind == POCKET_EVENT_UNDO) {
            last_presentation = POCKET_LOG_UNKNOWN; last_revealed = false;
        }
        last = event; have = true;
    }
    if (have && (last.after_revision != e->state.revision || last.after_checksum != e->state.checksum)) return false;
    if (e->booted != have || (!e->booted && (e->recording.presented || e->recording.revealed))) return false;
    if (e->recording.session != last_boot || e->recording.presented != (last_presentation != POCKET_LOG_UNKNOWN) ||
        e->recording.revealed != last_revealed || e->recording.presentation != last_presentation ||
        (e->booted && e->recording.presented != (e->state.body.length != 0))) return false;
    if (e->recording.presented) {
        pocket_event_t p; pocket_record_status_t status;
        if (!e->state.body.length || e->recording.presentation == 0 || e->recording.presentation > e->log.next_slot ||
            !pocket_log_read(&e->log, e->recording.presentation - 1, &p, &status) || p.kind != POCKET_EVENT_PRESENT ||
            p.word != pocket_word_current_word(&e->state) || p.session != e->recording.session ||
            p.after_revision != e->state.revision || e->recording.presented_at < 0 || e->recording.presented_at > e->last_at) return false;
    }
    if (e->recording.revealed && (!e->recording.presented || e->recording.revealed_at < e->recording.presented_at || e->recording.revealed_at > e->last_at)) return false;
    if (e->booted) {
        pocket_event_t boot; pocket_record_status_t status;
        if (!e->recording.session || e->recording.session > e->log.next_slot ||
            !pocket_log_read(&e->log, e->recording.session - 1, &boot, &status) || boot.kind != POCKET_EVENT_BOOT) return false;
    }
    return true;
}
xkl_engine_t *xkl_engine_restore(const uint8_t *blob, size_t length) {
    if (!blob || length < SNAP_FIXED + POCKET_LOG_HEADER_BYTES || length > SNAP_FIXED + POCKET_LOG_BYTES+12u+22u*PROOF_MAX ||
        get32(blob) != SNAP_MAGIC || (get32(blob+4)!=1u && get32(blob+4)!=2u) || get32(blob + 8) != SNAP_HEADER ||
        get32(blob + 12) != POCKET_WORD_DECK_ID || get32(blob + 16) != POCKET_WORD_LOG_ALGORITHM ||
        get32(blob + 20) != XKL_WORD_COUNT || get32(blob + 24) != CHECKPOINT_BYTES || get32(blob + 32) != length ||
        get32(blob + length - 4) != crc32(blob, length - 4)) return NULL;
    uint32_t log_n = get32(blob + 28), flags = get32(blob + 36);
    bool volume=get32(blob+4)==2u;uint32_t extra=volume ? get32(blob+92) : 0;
    if (log_n < POCKET_LOG_HEADER_BYTES || log_n > POCKET_LOG_HEADER_BYTES + POCKET_LOG_CAPACITY * POCKET_LOG_RECORD_BYTES ||
        (log_n - POCKET_LOG_HEADER_BYTES) % POCKET_LOG_RECORD_BYTES || length != SNAP_FIXED + log_n+extra || (flags & ~15u) ||
        get64(blob + 48) > INT64_MAX || get64(blob + 56) > INT64_MAX || get64(blob + 64) > INT64_MAX) return NULL;
    if(!volume) { for (unsigned i = 72; i < SNAP_HEADER; ++i) if (blob[i]) return NULL; }
    else if(extra<12u || extra>12u+22u*PROOF_MAX) return NULL;
    xkl_engine_t *e = allocate_engine(); if (!e) return NULL;
    codec_t c = {NULL, blob + SNAP_HEADER, 0}; checkpoint_codec(&c, &e->state);
    size_t at = SNAP_HEADER + c.at;
    for (uint32_t i = 0; i < XKL_WORD_COUNT; ++i, at += 4) e->cards[i] = get32(blob + at);
    memcpy(e->log_bytes, blob + at, log_n);
    if (!state_consistent(e) || pocket_log_open(&e->log, log_io(e), POCKET_WORD_DECK_ID, XKL_WORD_COUNT, POCKET_WORD_LOG_ALGORITHM) != POCKET_LOG_READY ||
        e->log.next_slot != (log_n - POCKET_LOG_HEADER_BYTES) / POCKET_LOG_RECORD_BYTES) goto error;
    pocket_word_recording_init(&e->recording, &e->log);
    e->booted = (flags & 1) != 0; e->recording.presented = (flags & 2) != 0;
    e->recording.revealed = (flags & 4) != 0; e->recording.resumed_next = (flags & 8) != 0;
    e->recording.session = get32(blob + 40); e->recording.presentation = get32(blob + 44);
    e->recording.presented_at = (int64_t)get64(blob + 48); e->recording.revealed_at = (int64_t)get64(blob + 56);
    e->last_at = (int64_t)get64(blob + 64);
    e->volume_mode=volume;
    if(volume) {
        e->sequence_offset=get32(blob+72);e->carry_count=get32(blob+76);
        e->carry_presentation=get32(blob+80);e->carry_session=get32(blob+84);e->carry_undo=get32(blob+88);
        if(e->carry_count<1u || e->carry_count>3u || e->carry_count>e->log.next_slot ||
           e->sequence_offset>UINT32_MAX-e->log.next_slot-1u) goto error;
        at+=log_n;e->proof_day=get32(blob+at);e->proof_first=get32(blob+at+4);e->proof_count=get32(blob+at+8);at+=12;
        if(e->proof_count>PROOF_MAX || extra!=12u+22u*e->proof_count || !e->proof_first ||
           e->proof_first>e->sequence_offset+e->log.next_slot+1u || e->proof_day<18000u || e->proof_day>50000u) goto error;
        for(unsigned i=0;i<e->proof_count;++i) {
            proof_t *p=&e->proofs[i];codec_t pc={NULL,blob+at,0};
            code32(&pc,&p->word);for(unsigned j=0;j<7;++j) code16(&pc,&p->seen[j]);
            code8(&pc,&p->distinct);code8(&pc,&p->recalls);code8(&pc,&p->anchored);code8(&pc,&p->long_gap);at+=pc.at;
            if(p->word>=XKL_WORD_COUNT || p->distinct>7u || p->recalls>3u || p->anchored>1u || p->long_gap>1u) goto error;
            for(unsigned j=0;j<i;++j) if(e->proofs[j].word==p->word) goto error;
            for(unsigned j=0;j<p->distinct;++j) {
                if(p->seen[j]>=XKL_WORD_COUNT || p->seen[j]==p->word) goto error;
                for(unsigned k=0;k<j;++k) if(p->seen[k]==p->seen[j]) goto error;
            }
        }
    }
    if (!log_state_consistent(e)) goto error;
    return e;
error:
    xkl_engine_free(e); return NULL;
}
uint32_t xkl_engine_pending_stages(const xkl_engine_t *e, uint32_t word,
    uint32_t *failed_round) {
    if (failed_round) *failed_round = 0;
    if (!live_ready(e) || word >= XKL_WORD_COUNT) return 0;
    for (unsigned slot = 0; slot < POCKET_ACTIVE_MAX; ++slot) {
        const pocket_cached_t *active = &e->state.body.active[slot];
        if (!active->used || active->word != word) continue;
        uint32_t mask = 0;
        for (unsigned i = 0; i < e->state.body.length; ++i)
            if (e->state.body.queue[i].slot == slot) mask |= 1u << e->state.body.queue[i].stage;
        if (failed_round) *failed_round = active->failed_round;
        return mask;
    }
    return 0;
}

bool xkl_engine_reconcile_collection(xkl_engine_t *e,
    uint32_t old_count, uint32_t new_count, const uint8_t *enabled,
    const uint32_t *activated_cards, int64_t at,
    const uint8_t *pending_stages, const uint8_t *failed_rounds) {
    const uint32_t inert = pocket_pack_card((pocket_card_t){.due_day = UINT32_MAX, .learned = 1}) | POCKET_IMPORTED_KNOWN;
    if (!live_ready(e) || !old_count || old_count > new_count || new_count > XKL_WORD_COUNT ||
        !enabled || !activated_cards || at < 0 || (pending_stages == NULL) != (failed_rounds == NULL) ||
        !state_consistent(e) || !log_state_consistent(e)) return false;
    bool changed = old_count != new_count, incoming_pending = false;
    for (uint32_t i = 0; i < new_count; ++i) {
        if (enabled[i] > 1u || !pocket_word_card_valid(activated_cards[i])) return false;
        if (i < old_count && enabled[i] && e->cards[i] != inert && activated_cards[i] != e->cards[i]) return false;
        if (enabled[i] && (i >= old_count || e->cards[i] == inert) && pending_stages) {
            uint8_t stages = pending_stages[i], failed = failed_rounds[i];
            pocket_card_t card = pocket_unpack_card(activated_cards[i]);
            if (failed > 2u || (!stages && failed) ||
                (stages && (card.familiar || (card.learned && !card.level))) ||
                ((stages & 1u) && stages != 1u) ||
                (stages && !failed && stages != 1u) ||
                (failed == 1u && ((stages & 1u) || card.level != 1u || (activated_cards[i] & POCKET_WORD_PARTIAL_PENDING))) ||
                (failed == 2u && (stages != 1u || !(activated_cards[i] & POCKET_WORD_PARTIAL_PENDING)))) return false;
            if (stages) incoming_pending = true;
        }
        uint32_t desired = enabled[i] ? activated_cards[i] : inert;
        if (e->cards[i] != desired) changed = true;
    }
    for (uint32_t i = old_count; i < XKL_WORD_COUNT; ++i)
        if (e->cards[i] != inert) return false; /* Reject an incorrect old mapping boundary. */
    if (!changed) return true;
    if (!room(e, 7u) || e->state.revision >= UINT32_MAX - 1u) return false;
    size_t size = xkl_engine_snapshot_size(e);
    uint8_t *bytes = malloc(size);
    if (!bytes) return false;
    if (xkl_engine_snapshot(e, bytes, size) != size) { free(bytes); return false; }
    xkl_engine_t *candidate = xkl_engine_restore(bytes, size);
    free(bytes);
    if (!candidate) return false;
    const uint16_t old_head = pocket_word_current_word(&e->state);
    const bool was_revealed = e->recording.revealed;
    if (!clock_ok(candidate, at)) {
        /* Rebase only the recording session. Running the ordinary task picker
         * here would consume the new-card quota before deferred obligations
         * are restored. The metadata START below seals/presents this state. */
        pocket_word_recording_init(&candidate->recording, &candidate->log);
        if (!pocket_word_recording_boot(&candidate->recording, &candidate->state, at)) goto error;
        candidate->booted = true; candidate->last_at = at;
    }

    pocket_word_state_t next = candidate->state;
    pocket_word_body_t *b = &next.body;
    if (!b->length && incoming_pending) {
        /* Completed tasks retain done counters until a new task starts. This
         * is that explicit boundary, with transferred work admitted before
         * ordinary fresh selection. The old state stays in the log/snapshot. */
        uint32_t day = b->day, selection_day = b->selection_day;
        memset(b, 0, sizeof(*b)); b->day = day; b->selection_day = selection_day;
    }
    next.can_undo = 0; next.changed_word = POCKET_NO_WORD; next.changed_card = 0;
    for (uint32_t i = 0; i < new_count; ++i) candidate->cards[i] = enabled[i] ? activated_cards[i] : inert;
    for (uint32_t i = new_count; i < XKL_WORD_COUNT; ++i) candidate->cards[i] = inert;
    unsigned kept = 0;
    for (unsigned i = 0; i < b->length; ++i) {
        pocket_token_t token = b->queue[i];
        const pocket_cached_t *active = &b->active[token.slot];
        if (active->word < new_count && enabled[active->word]) b->queue[kept++] = token;
    }
    memset(b->queue + kept, 0, (b->length - kept) * sizeof(b->queue[0]));
    b->length = (uint16_t)kept;
    for (unsigned slot = 0; slot < POCKET_ACTIVE_MAX; ++slot) {
        pocket_cached_t *active = &b->active[slot];
        if (!active->used) continue;
        if (active->word >= new_count || !enabled[active->word]) {
            memset(active, 0, sizeof(*active)); continue;
        }
    }
    if (pending_stages) for (uint32_t i = 0; i < new_count; ++i) {
        if (!enabled[i] || !pending_stages[i] || (i < old_count && e->cards[i] != inert)) continue;
        unsigned slot = 0;
        while (slot < POCKET_ACTIVE_MAX && b->active[slot].used) ++slot;
        if (slot == POCKET_ACTIVE_MAX) goto error;
        b->active[slot] = (pocket_word_cached_t){activated_cards[i], (uint16_t)i, failed_rounds[i], 1};
        for (unsigned stage = 0; stage < 8; ++stage) if (pending_stages[i] & (1u << stage)) {
            if (b->length == POCKET_QUEUE_MAX) goto error;
            b->queue[b->length++] = (pocket_token_t){(uint8_t)slot, (uint8_t)stage};
        }
    }
    unsigned active_new = 0, active_review = 0;
    for (unsigned slot = 0; slot < POCKET_ACTIVE_MAX; ++slot) {
        const pocket_cached_t *active = &b->active[slot];
        if (!active->used) continue;
        if (pocket_unpack_card(active->packed).learned) ++active_review;
        else {
            ++active_new;
            if (!b->lesson) {
                b->lesson = (uint16_t)(active->word / POCKET_LESSON_SIZE + 1u);
                b->new_cursor = b->new_end = (uint16_t)(active->word + 1u);
            }
        }
    }
    unsigned waiting_review = 0, waiting_new = 0;
    if (b->length) {
        for (uint32_t i = 0; i < new_count; ++i) {
            if (!enabled[i]) continue;
            bool active = false;
            for (unsigned slot = 0; slot < POCKET_ACTIVE_MAX; ++slot)
                if (b->active[slot].used && b->active[slot].word == i) { active = true; break; }
            if (active) continue;
            pocket_card_t card = pocket_unpack_card(candidate->cards[i]);
            if (!card.familiar && card.learned && card.level && card.due_day <= b->selection_day) ++waiting_review;
            if (!card.familiar && !card.learned && i >= b->new_cursor && i < b->new_end) ++waiting_new;
        }
    }
    uint32_t new_loaded = (uint32_t)b->new_done + active_new;
    uint32_t review_loaded = (uint32_t)b->review_done + active_review;
    uint32_t new_total = new_loaded + waiting_new, review_total = review_loaded + waiting_review;
    if (new_total > POCKET_LESSON_SIZE || review_total > UINT16_MAX || new_total + review_total > XKL_WORD_COUNT) goto error;
    b->new_loaded = (uint16_t)new_loaded; b->new_total = (uint16_t)new_total;
    b->review_loaded = (uint16_t)review_loaded; b->review_total = (uint16_t)review_total; b->review_cursor = 0;
    if (!new_total) b->lesson = b->new_cursor = b->new_end = 0;
    if (!pocket_word_recording_commit(&candidate->recording, &candidate->state, &next,
            POCKET_EVENT_START, at, card_read, state_store, candidate) ||
        !pocket_word_recording_present(&candidate->recording, &candidate->state, at)) goto error;
    candidate->last_at = at;
    if (was_revealed && old_head != POCKET_NO_WORD && old_head == pocket_word_current_word(&candidate->state) &&
        !xkl_engine_reveal(candidate, at)) goto error;
    if (!state_consistent(candidate) || !log_state_consistent(candidate)) goto error;
    /* The only publication point. Rebind internal callbacks after moving the
     * complete verified candidate; errors above never touch the live object. */
    uint8_t *old_log_bytes = e->log_bytes;
    *e = *candidate;
    e->log.io.context = e; e->recording.log = &e->log;
    free(old_log_bytes); free(candidate);
    return true;
error:
    xkl_engine_free(candidate); return false;
}

bool xkl_engine_can_postpone_professional(const xkl_engine_t *e) {
    if (!live_ready(e) || !e->state.body.length) return false;
    const pocket_word_body_t *b = &e->state.body;
    uint16_t word = b->active[b->queue[0].slot].word;
    for (unsigned i = 1; i < b->length; ++i)
        if (b->active[b->queue[i].slot].word != word) return true;
    return false;
}
bool xkl_engine_postpone_professional(xkl_engine_t *e, int64_t at) {
    if (!clock_ok(e, at) || !room(e, 2) || e->state.revision == UINT32_MAX ||
        !xkl_engine_can_postpone_professional(e) || !state_consistent(e) || !log_state_consistent(e)) return false;
    size_t size = xkl_engine_snapshot_size(e);
    uint8_t *bytes = malloc(size);
    if (!bytes) return false;
    if (xkl_engine_snapshot(e, bytes, size) != size) { free(bytes); return false; }
    xkl_engine_t *candidate = xkl_engine_restore(bytes, size);
    free(bytes);
    if (!candidate) return false;
    pocket_word_state_t next = candidate->state;
    const pocket_word_body_t *old = &candidate->state.body;
    uint16_t word = old->active[old->queue[0].slot].word;
    unsigned count = 0;
    for (unsigned i = 0; i < old->length; ++i)
        if (old->active[old->queue[i].slot].word != word) next.body.queue[count++] = old->queue[i];
    for (unsigned i = 0; i < old->length; ++i)
        if (old->active[old->queue[i].slot].word == word) next.body.queue[count++] = old->queue[i];
    next.can_undo = 0; next.changed_word = POCKET_NO_WORD; next.changed_card = 0;
    if (!pocket_word_recording_commit(&candidate->recording, &candidate->state, &next,
            POCKET_EVENT_START, at, card_read, state_store, candidate) ||
        !pocket_word_recording_present(&candidate->recording, &candidate->state, at)) goto postpone_error;
    candidate->last_at = at;
    if (!state_consistent(candidate) || !log_state_consistent(candidate)) goto postpone_error;
    uint8_t *old_log = e->log_bytes;
    *e = *candidate; e->log.io.context = e; e->recording.log = &e->log;
    free(old_log); free(candidate); return true;
postpone_error:
    xkl_engine_free(candidate); return false;
}

bool xkl_engine_info(const xkl_engine_t *e, xkl_info_t *info) {
    if (!live_ready(e) || !info) return false;
    memset(info, 0, sizeof(*info));
    uint16_t word = pocket_word_current_word(&e->state);
    info->word = word == POCKET_NO_WORD ? XKL_NO_WORD : word;
    info->day = e->state.body.day; info->lesson = e->state.body.lesson;
    info->new_remaining = pocket_word_new_remaining(&e->state); info->review_remaining = pocket_word_review_remaining(&e->state);
    info->total_remaining = pocket_word_unique_remaining(&e->state); info->completed = e->state.body.completed + e->state.body.skipped;
    info->stage = e->state.body.length ? e->state.body.queue[0].stage : 0;
    info->can_undo = e->state.can_undo; info->revision = e->state.revision;
    info->first_known = pocket_word_first_known_count(&e->state); info->familiar = pocket_word_familiar_count(&e->state);
    info->log_records = e->sequence_offset+e->log.next_slot; info->log_capacity = POCKET_LOG_CAPACITY;
    info->partial_gap = word == POCKET_NO_WORD ? 0 : pocket_word_partial_gap(&e->state, word);
    info->revealed = e->recording.revealed; info->partial_pending = pocket_word_current_partial(&e->state);
    info->has_task = e->state.body.length != 0;
    info->selection_day = e->state.body.selection_day;
    return true;
}
uint32_t xkl_engine_card(const xkl_engine_t *e, uint32_t word) { return e && word < XKL_WORD_COUNT ? e->cards[word] : UINT32_MAX; }
uint32_t xkl_engine_log_base(const xkl_engine_t *e) { return live_ready(e) ? e->sequence_offset+e->carry_count : UINT32_MAX; }
uint32_t xkl_engine_volume_records(const xkl_engine_t *e) { return live_ready(e) ? e->log.next_slot : UINT32_MAX; }
bool xkl_engine_rotate_log(xkl_engine_t *e,uint32_t first) {
    if(!live_ready(e) || !e->booted || !first || first>e->sequence_offset+e->log.next_slot+1u) return false;
    proof_t proofs[PROOF_MAX];unsigned count=0;
    for(unsigned b=0;b<2;++b) {
        if(b && !e->state.can_undo) continue;
        const pocket_body_t *body=b ? &e->state.undo:&e->state.body;
        for(unsigned i=0;i<POCKET_ACTIVE_MAX;++i) if(body->active[i].used) {
            uint32_t word=body->active[i].word;bool found=false;
            for(unsigned j=0;j<count;++j) if(proofs[j].word==word) found=true;
            if(!found && !proof_for(e,word,first,&proofs[count++])) return false;
        }
    }
    uint32_t undo=UINT32_MAX;
    if(e->state.can_undo && !pocket_log_find_undo(&e->log,e->state.undo_word,e->cards[e->state.undo_word],&undo)) return false;
    if(undo==UINT32_MAX && e->volume_mode) undo=e->carry_undo;
    uint32_t total=e->sequence_offset+e->log.next_slot;
    uint32_t presentation=global_presentation(e,e->recording.presentation);
    uint32_t session=e->volume_mode && e->recording.session==1u ? e->carry_session:global_sequence(e,e->recording.session);
    pocket_word_recording_t old=e->recording;uint32_t stream[4];memcpy(stream,e->log.stream,sizeof(stream));
    const uint32_t carry=1u+(old.presented ? 1u:0u)+(old.revealed ? 1u:0u);
    if(total<carry) return false;
    memset(e->log_bytes,255,POCKET_LOG_BYTES);
    if(pocket_log_open(&e->log,log_io(e),POCKET_WORD_DECK_ID,XKL_WORD_COUNT,POCKET_WORD_LOG_ALGORITHM)!=POCKET_LOG_EMPTY ||
       !pocket_log_create(&e->log,stream)) return false;
    pocket_word_recording_init(&e->recording,&e->log);
    if(!pocket_word_recording_boot(&e->recording,&e->state,e->last_at)) return false;
    if(old.presented && !pocket_word_recording_present(&e->recording,&e->state,old.presented_at)) return false;
    if(old.revealed && !pocket_word_recording_reveal(&e->recording,&e->state,old.revealed_at)) return false;
    e->volume_mode=true;e->sequence_offset=total-carry;e->carry_count=carry;
    e->carry_presentation=presentation;e->carry_session=session;e->carry_undo=undo;
    e->proof_day=e->state.body.day;e->proof_first=first;e->proof_count=count;
    memcpy(e->proofs,proofs,count*sizeof(*proofs));
    return state_consistent(e) && log_state_consistent(e);
}
