#include "pocket_log.h"
#include <string.h>

#define HEADER_WORDS 16u
#define RECORD_WORDS 24u
#define LOG_VERSION 1u

static uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void put32(uint8_t *p, uint32_t x) {
    p[0] = (uint8_t)x; p[1] = (uint8_t)(x >> 8);
    p[2] = (uint8_t)(x >> 16); p[3] = (uint8_t)(x >> 24);
}
static uint32_t crc32(const uint8_t *p, size_t n) {
    uint32_t c = UINT32_MAX;
    while (n--) {
        c ^= *p++;
        for (unsigned bit = 0; bit < 8; ++bit)
            c = (c >> 1) ^ (UINT32_C(0xedb88320) & (0u - (c & 1u)));
    }
    return ~c;
}
static bool erased(const uint8_t *p, size_t n) {
    while (n--) if (*p++ != 255u) return false;
    return true;
}
static bool fail(pocket_log_t *l) {
    l->failed = true;
    l->ready = false;
    return false;
}
static bool read_bytes(pocket_log_t *l, uint32_t at, void *p, size_t n) {
    if (at > l->io.size || n > l->io.size - at ||
        !l->io.read(l->io.context, at, p, n)) return fail(l);
    return true;
}
static bool write_bytes(pocket_log_t *l, uint32_t at, const void *p, size_t n) {
    if (at > l->io.size || n > l->io.size - at ||
        !l->io.write(l->io.context, at, p, n)) return fail(l);
    return true;
}
static bool erased_range(pocket_log_t *l, uint32_t at, uint32_t n) {
    uint8_t bytes[256];
    while (n) {
        size_t count = n > sizeof(bytes) ? sizeof(bytes) : n;
        if (!read_bytes(l, at, bytes, count) || !erased(bytes, count)) return false;
        at += (uint32_t)count; n -= (uint32_t)count;
    }
    return true;
}
static void event_words(const pocket_event_t *e, uint32_t w[20]) {
    w[0] = e->sequence; w[1] = e->kind; w[2] = e->day; w[3] = e->session;
    w[4] = e->task_day; w[5] = e->uptime_ms; w[6] = e->word; w[7] = e->stage;
    w[8] = e->before_card; w[9] = e->after_card;
    w[10] = e->before_revision; w[11] = e->after_revision;
    w[12] = e->before_checksum; w[13] = e->after_checksum;
    w[14] = e->presentation; w[15] = e->reveal_ms; w[16] = e->answer_ms;
    w[17] = e->undo_revision; w[18] = e->algorithm; w[19] = e->flags;
}
static void decode_event(const uint8_t *bytes, pocket_event_t *e) {
    uint32_t w[20];
    for (unsigned i = 0; i < 20; ++i) w[i] = get32(bytes + 4u + i * 4u);
    *e = (pocket_event_t){
        .sequence = w[0], .kind = w[1], .day = w[2], .session = w[3],
        .task_day = w[4], .uptime_ms = w[5], .word = w[6], .stage = w[7],
        .before_card = w[8], .after_card = w[9],
        .before_revision = w[10], .after_revision = w[11],
        .before_checksum = w[12], .after_checksum = w[13],
        .presentation = w[14], .reveal_ms = w[15], .answer_ms = w[16],
        .undo_revision = w[17], .algorithm = w[18], .flags = w[19]};
}
static bool valid_event(const pocket_log_t *l, const pocket_event_t *e) {
    return e->kind >= POCKET_EVENT_BOOT && e->kind <= POCKET_EVENT_PARTIAL &&
        (e->kind != POCKET_EVENT_PARTIAL || l->algorithm == 3u) &&
        e->algorithm == l->algorithm &&
        (e->word == POCKET_LOG_UNKNOWN || e->word < l->word_count) &&
        !(e->flags & ~(POCKET_EVENT_REVEALED | POCKET_EVENT_RESUME |
                      POCKET_EVENT_TIME_UNKNOWN | POCKET_EVENT_UNDO_UNKNOWN));
}
static uint32_t record_offset(uint32_t slot) {
    return POCKET_LOG_HEADER_BYTES + slot * POCKET_LOG_RECORD_BYTES;
}
static bool compatible(uint32_t value, uint32_t target) {
    return (value & target) == target;
}
static bool read_record(pocket_log_t *l, uint32_t slot, pocket_event_t *e,
                        pocket_record_status_t *status) {
    uint8_t bytes[POCKET_LOG_RECORD_BYTES];
    if (!read_bytes(l, record_offset(slot), bytes, sizeof(bytes))) return false;
    memset(e, 0, sizeof(*e));
    if (erased(bytes, sizeof(bytes))) {
        *status = POCKET_RECORD_UNUSED;
        return true;
    }
    uint32_t prepared = get32(bytes + 88), terminal = get32(bytes + 92);
    if (prepared != POCKET_LOG_PREPARED) {
        /* State cannot have been committed before a verified prepare marker. */
        if (terminal != UINT32_MAX) return fail(l);
        *status = POCKET_RECORD_TORN;
        return true;
    }
    decode_event(bytes, e);
    if (get32(bytes) != POCKET_LOG_RECORD_MAGIC ||
        get32(bytes + 84) != crc32(bytes, 84) ||
        e->sequence != slot + 1u || !valid_event(l, e)) return fail(l);
    if (terminal == POCKET_LOG_COMMITTED) *status = POCKET_RECORD_COMMITTED;
    else if (terminal == POCKET_LOG_ABORTED) *status = POCKET_RECORD_ABORTED;
    else if (compatible(terminal, POCKET_LOG_COMMITTED) ||
             compatible(terminal, POCKET_LOG_ABORTED)) *status = POCKET_RECORD_PENDING;
    else return fail(l);
    return true;
}
pocket_log_result_t pocket_log_open(pocket_log_t *l, pocket_storage_io_t io,
    uint32_t deck_id, uint32_t word_count, uint32_t algorithm) {
    if (!l) return POCKET_LOG_ERROR;
    memset(l, 0, sizeof(*l));
    l->io = io; l->deck_id = deck_id; l->word_count = word_count;
    l->algorithm = algorithm; l->pending_slot = POCKET_LOG_UNKNOWN;
    if (!io.read || !io.write || io.size != POCKET_LOG_BYTES ||
        !word_count || !algorithm) goto error;
    uint8_t header[HEADER_WORDS * 4u];
    if (!read_bytes(l, 0, header, sizeof(header))) goto error;
    if (erased(header, sizeof(header))) {
        if (!erased_range(l, sizeof(header), io.size - sizeof(header))) goto error;
        l->empty = true;
        return POCKET_LOG_EMPTY;
    }
    if (get32(header) != POCKET_LOG_MAGIC || get32(header + 4) != LOG_VERSION ||
        get32(header + 8) != deck_id || get32(header + 12) != algorithm ||
        get32(header + 16) != word_count ||
        get32(header + 20) != POCKET_LOG_RECORD_BYTES ||
        get32(header + 24) != POCKET_LOG_BYTES || get32(header + 28) ||
        get32(header + 48) || get32(header + 52) ||
        get32(header + 56) != crc32(header, 56) ||
        get32(header + 60) != POCKET_LOG_COMMITTED ||
        !erased_range(l, sizeof(header), POCKET_LOG_HEADER_BYTES - sizeof(header))) goto error;
    for (unsigned i = 0; i < 4; ++i) l->stream[i] = get32(header + 32 + i * 4);
    for (uint32_t slot = 0; slot < POCKET_LOG_CAPACITY; ++slot) {
        pocket_event_t e;
        pocket_record_status_t status;
        if (!read_record(l, slot, &e, &status)) goto error;
        if (status == POCKET_RECORD_UNUSED) {
            uint32_t at = record_offset(slot + 1u);
            if (!erased_range(l, at, io.size - at)) goto error;
            l->next_slot = slot;
            l->ready = true;
            return POCKET_LOG_READY;
        }
        /* Any occupied slot after a pending state breaks the recovery contract. */
        if (l->pending_slot != POCKET_LOG_UNKNOWN) goto error;
        if (status == POCKET_RECORD_PENDING) {
            l->pending_slot = slot;
            l->pending = e;
        }
        l->next_slot = slot + 1u;
    }
    if (!erased_range(l, record_offset(POCKET_LOG_CAPACITY),
                      io.size - record_offset(POCKET_LOG_CAPACITY))) goto error;
    l->full = true; l->ready = true;
    return POCKET_LOG_READY;
error:
    fail(l);
    return POCKET_LOG_ERROR;
}
bool pocket_log_create(pocket_log_t *l, const uint32_t stream[4]) {
    if (!l || !stream || l->failed || !l->empty || l->ready) return false;
    uint8_t bytes[HEADER_WORDS * 4u], verify[HEADER_WORDS * 4u];
    const uint32_t w[HEADER_WORDS] = {POCKET_LOG_MAGIC, LOG_VERSION, l->deck_id,
        l->algorithm, l->word_count, POCKET_LOG_RECORD_BYTES, POCKET_LOG_BYTES, 0,
        stream[0], stream[1], stream[2], stream[3], 0, 0, 0, POCKET_LOG_COMMITTED};
    for (unsigned i = 0; i < HEADER_WORDS; ++i) put32(bytes + i * 4u, w[i]);
    put32(bytes + 56, crc32(bytes, 56));
    if (!write_bytes(l, 0, bytes, 60) || !read_bytes(l, 0, verify, 60) ||
        memcmp(bytes, verify, 60)) return fail(l);
    if (!write_bytes(l, 60, bytes + 60, 4) ||
        !read_bytes(l, 0, verify, sizeof(verify)) ||
        memcmp(bytes, verify, sizeof(bytes))) return fail(l);
    memcpy(l->stream, stream, sizeof(l->stream));
    l->empty = false; l->ready = true;
    return true;
}
bool pocket_log_read(pocket_log_t *l, uint32_t slot, pocket_event_t *e,
                     pocket_record_status_t *status) {
    if (!l || !e || !status || !l->ready || l->failed ||
        slot >= POCKET_LOG_CAPACITY) return false;
    return read_record(l, slot, e, status);
}
bool pocket_log_prepare(pocket_log_t *l, const pocket_event_t *event, uint32_t *sequence) {
    if (!l || !event || !l->ready || l->failed || l->full ||
        l->pending_slot != POCKET_LOG_UNKNOWN || !valid_event(l, event)) return false;
    uint8_t bytes[POCKET_LOG_RECORD_BYTES], verify[POCKET_LOG_RECORD_BYTES];
    memset(bytes, 255, sizeof(bytes));
    pocket_event_t e = *event;
    e.sequence = l->next_slot + 1u;
    uint32_t w[20];
    event_words(&e, w);
    put32(bytes, POCKET_LOG_RECORD_MAGIC);
    for (unsigned i = 0; i < 20; ++i) put32(bytes + 4 + i * 4u, w[i]);
    put32(bytes + 84, crc32(bytes, 84));
    put32(bytes + 88, POCKET_LOG_PREPARED);
    uint32_t at = record_offset(l->next_slot);
    if (!read_bytes(l, at, verify, sizeof(verify)) || !erased(verify, sizeof(verify)))
        return fail(l);
    if (!write_bytes(l, at, bytes, 88) || !read_bytes(l, at, verify, 88) ||
        memcmp(bytes, verify, 88)) return fail(l);
    if (!write_bytes(l, at + 88, bytes + 88, 4) ||
        !read_bytes(l, at, verify, sizeof(verify)) ||
        memcmp(bytes, verify, sizeof(bytes))) return fail(l);
    l->pending_slot = l->next_slot++;
    l->pending = e;
    l->full = l->next_slot == POCKET_LOG_CAPACITY;
    if (sequence) *sequence = e.sequence;
    return true;
}
bool pocket_log_finalize(pocket_log_t *l, bool committed) {
    if (!l || !l->ready || l->failed || l->pending_slot == POCKET_LOG_UNKNOWN) return false;
    uint32_t marker = committed ? POCKET_LOG_COMMITTED : POCKET_LOG_ABORTED;
    uint8_t current[4], target[4];
    uint32_t at = record_offset(l->pending_slot) + 92;
    if (!read_bytes(l, at, current, sizeof(current)) ||
        !compatible(get32(current), marker)) return fail(l);
    put32(target, marker);
    if (!write_bytes(l, at, target, sizeof(target)) ||
        !read_bytes(l, at, current, sizeof(current)) ||
        memcmp(current, target, sizeof(target))) return fail(l);
    l->pending_slot = POCKET_LOG_UNKNOWN;
    memset(&l->pending, 0, sizeof(l->pending));
    return true;
}
bool pocket_log_recover(pocket_log_t *l, uint32_t revision, uint32_t checksum) {
    if (!l || !l->ready || l->failed) return false;
    if (l->pending_slot == POCKET_LOG_UNKNOWN) return true;
    if (l->pending.after_revision == revision && l->pending.after_checksum == checksum)
        return pocket_log_finalize(l, true);
    if (l->pending.before_revision == revision && l->pending.before_checksum == checksum)
        return pocket_log_finalize(l, false);
    return fail(l);
}
bool pocket_log_append(pocket_log_t *l, const pocket_event_t *e, uint32_t *sequence) {
    return pocket_log_prepare(l, e, sequence) && pocket_log_finalize(l, true);
}
bool pocket_log_find_undo(pocket_log_t *l, uint32_t word, uint32_t before_card,
                          uint32_t *revision) {
    if (!l || !revision || !l->ready || l->failed || word >= l->word_count) return false;
    *revision = POCKET_LOG_UNKNOWN;
    for (uint32_t slot = l->next_slot; slot; ) {
        pocket_event_t e;
        pocket_record_status_t status;
        if (!pocket_log_read(l, --slot, &e, &status)) return false;
        if (status == POCKET_RECORD_COMMITTED &&
            (e.kind == POCKET_EVENT_CORRECT || e.kind == POCKET_EVENT_FAMILIAR) &&
            e.word == word && e.after_card == before_card) {
            *revision = e.after_revision;
            return true;
        }
    }
    return true;
}
