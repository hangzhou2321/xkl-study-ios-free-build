#include "pocket_word_model.h"
#include "pocket_review_intervals.h"
#include <string.h>

bool pocket_word_card_valid(uint32_t p) {
    pocket_card_t c = pocket_unpack_card(p);
    if ((p >> 24) || c.level > POCKET_MAX_LEVEL) return false;
    /* Imported overdue dates can predate the device's interactive calendar. */
    if (c.level && (c.due_day < 1 || c.due_day > 50180)) return false;
    if (!c.level && c.learned && c.due_day != UINT32_MAX) return false;
    if (!c.level && !c.learned && c.due_day) return false;
    if ((p & POCKET_IMPORTED_KNOWN) && (!c.learned || c.level || c.familiar || c.due_day != UINT32_MAX)) return false;
    if ((p & POCKET_WORD_PARTIAL_PENDING) &&
        (!c.level || c.familiar || (p & POCKET_IMPORTED_KNOWN))) return false;
    return true;
}
static bool due_card(pocket_card_t c, uint32_t day) {
    return !c.familiar && c.learned && c.level >= 1 && c.level <= POCKET_MAX_LEVEL && c.due_day <= day;
}
static uint32_t crc32(const void *data, size_t size) {
    const uint8_t *p = data; uint32_t crc = UINT32_MAX;
    while (size--) {
        crc ^= *p++;
        for (unsigned i = 0; i < 8; ++i)
            crc = (crc >> 1) ^ (UINT32_C(0xedb88320) & (0u - (crc & 1u)));
    }
    return ~crc;
}
void pocket_word_seal(pocket_word_state_t *s) { s->checksum = crc32(s, offsetof(pocket_word_state_t, checksum)); }
void pocket_word_init(pocket_word_state_t *s) {
    memset(s, 0, sizeof(*s));
    s->magic = POCKET_WORD_MAGIC; s->version = POCKET_WORD_VERSION; s->deck_id = POCKET_WORD_DECK_ID;
    s->body.day = s->body.selection_day = POCKET_INITIAL_DAY;
    s->changed_word = s->undo_word = POCKET_NO_WORD;
    pocket_word_seal(s);
}
static bool body_valid(const pocket_word_body_t *b) {
    if (b->length > POCKET_QUEUE_MAX || b->day < 18000 || b->day > 50000 ||
        b->selection_day < 18000 || b->selection_day > 50000 ||
        b->new_total > POCKET_LESSON_SIZE || (unsigned)b->review_total + b->new_total > POCKET_WORD_COUNT ||
        b->new_done > b->new_loaded || b->new_loaded > b->new_total ||
        b->review_done > b->review_loaded || b->review_loaded > b->review_total ||
        (unsigned)b->completed + b->skipped != (unsigned)b->new_done + b->review_done ||
        b->first_known > b->new_done || b->first_known > b->completed ||
        b->lesson > POCKET_LESSON_COUNT || ((b->lesson == 0) != (b->new_total == 0)) ||
        b->review_cursor > POCKET_WORD_COUNT || b->new_cursor > b->new_end || b->new_end > POCKET_WORD_COUNT ||
        (unsigned)b->total_familiar + b->total_first_known > POCKET_WORD_COUNT) return false;
    uint8_t stages[POCKET_ACTIVE_MAX] = {0};
    for (unsigned i = 0; i < b->length; ++i) {
        const pocket_token_t *t = &b->queue[i];
        if (t->slot >= POCKET_ACTIVE_MAX || t->stage > 7 || !b->active[t->slot].used) return false;
        uint8_t *mask = &stages[t->slot];
        if (*mask & (1u << t->stage)) return false;
        *mask |= 1u << t->stage;
        if ((*mask & 1) && *mask != 1) return false;
    }
    unsigned active_new = 0, active_review = 0;
    for (unsigned i = 0; i < POCKET_ACTIVE_MAX; ++i) {
        const pocket_word_cached_t *a = &b->active[i];
        if (a->used > 1 || a->failed_round > 2) return false;
        if (!a->used) continue;
        if (!stages[i] || a->word >= POCKET_WORD_COUNT || !pocket_word_card_valid(a->packed)) return false;
        pocket_card_t c = pocket_unpack_card(a->packed);
        if (c.familiar || (c.learned && c.level == 0)) return false;
        if (a->failed_round == 1 && ((stages[i] & 1) ||
            (a->packed & POCKET_WORD_PARTIAL_PENDING) || c.level != 1)) return false;
        if (a->failed_round == 2 && (stages[i] != 1 ||
            !(a->packed & POCKET_WORD_PARTIAL_PENDING))) return false;
        if (!a->failed_round && stages[i] != 1) return false;
        if (c.learned) ++active_review; else ++active_new;
        for (unsigned j = 0; j < i; ++j)
            if (b->active[j].used && b->active[j].word == a->word) return false;
    }
    return active_new == (unsigned)b->new_loaded - b->new_done &&
        active_review == (unsigned)b->review_loaded - b->review_done &&
        (b->length || ((b->new_done == b->new_total) && (b->review_done == b->review_total)));
}
bool pocket_word_valid(const pocket_word_state_t *s) {
    return s && s->magic == POCKET_WORD_MAGIC && s->version == POCKET_WORD_VERSION && s->deck_id == POCKET_WORD_DECK_ID &&
        s->can_undo <= 1 && body_valid(&s->body) &&
        (!s->can_undo || (s->undo_word < POCKET_WORD_COUNT && pocket_word_card_valid(s->undo_card) && body_valid(&s->undo))) &&
        (s->changed_word == POCKET_NO_WORD || (s->changed_word < POCKET_WORD_COUNT && pocket_word_card_valid(s->changed_card))) &&
        s->checksum == crc32(s, offsetof(pocket_word_state_t, checksum));
}
static bool read_card(pocket_word_read_fn read, void *ctx, uint16_t word, uint32_t *packed) {
    return read && read(word, packed, ctx) && pocket_word_card_valid(*packed);
}
/* fill runs before the candidate checkpoint/card is committed. In particular,
   after a calendar rescan the cursor may encounter the card just completed or
   restored by undo. Read its candidate value rather than the stale backing
   value, which could otherwise admit the same word twice. */
static bool candidate_card(const pocket_word_state_t *s, pocket_word_read_fn read,
                           void *ctx, uint16_t word, uint32_t *packed) {
    if (s->changed_word == word) {
        *packed = s->changed_card;
        return pocket_word_card_valid(*packed);
    }
    return read_card(read, ctx, word, packed);
}
static bool active_word(const pocket_word_body_t *b, uint16_t word) {
    for (unsigned i = 0; i < POCKET_ACTIVE_MAX; ++i)
        if (b->active[i].used && b->active[i].word == word) return true;
    return false;
}
/* Cache capacity is not a task quota: refill automatically until every selected
   due word and every new word in this lesson has been admitted. */
static bool fill(pocket_word_state_t *s, pocket_word_read_fn read, void *ctx) {
    pocket_word_body_t *b = &s->body;
    for (unsigned slot = 0; slot < POCKET_ACTIVE_MAX; ++slot) {
        if (b->active[slot].used) continue;
        uint16_t word = POCKET_NO_WORD; uint32_t packed = 0;
        if (b->review_loaded < b->review_total) {
            while (b->review_cursor < POCKET_WORD_COUNT) {
                uint16_t id = b->review_cursor++;
                if (active_word(b, id)) continue;
                if (!candidate_card(s, read, ctx, id, &packed)) return false;
                if (due_card(pocket_unpack_card(packed), b->selection_day)) { word = id; break; }
            }
            if (word == POCKET_NO_WORD) return false;
            ++b->review_loaded;
        } else if (b->new_loaded < b->new_total) {
            while (b->new_cursor < b->new_end) {
                uint16_t id = b->new_cursor++;
                if (active_word(b, id)) continue;
                if (!candidate_card(s, read, ctx, id, &packed)) return false;
                pocket_card_t c = pocket_unpack_card(packed);
                if (!c.learned && !c.familiar) { word = id; break; }
            }
            if (word == POCKET_NO_WORD) return false;
            ++b->new_loaded;
        } else break;
        if (b->length == POCKET_QUEUE_MAX) return false;
        b->active[slot] = (pocket_word_cached_t){packed, word, 0, 1};
        b->queue[b->length++] = (pocket_token_t){slot, 0};
    }
    return true;
}
bool pocket_word_refresh_due(pocket_word_state_t *s, uint32_t day,
                             pocket_word_read_fn read, void *ctx) {
    pocket_word_body_t *b = &s->body;
    if (day < 18000 || day > 50000 || day < b->day || day < b->selection_day) return false;
    b->day = day;
    /* selection_day is the admission cutoff, not merely the current display
       date. This also repairs legacy checkpoints already advanced to today
       while their nonempty task kept yesterday's cutoff. */
    if (!b->length || b->selection_day == day) return true;
    uint32_t active_review = 0, waiting = 0;
    for (unsigned i = 0; i < POCKET_ACTIVE_MAX; ++i)
        if (b->active[i].used && pocket_unpack_card(b->active[i].packed).learned) ++active_review;
    for (uint32_t id = 0; id < POCKET_WORD_COUNT; ++id) {
        if (active_word(b, (uint16_t)id)) continue;
        uint32_t packed;
        if (!candidate_card(s, read, ctx, (uint16_t)id, &packed)) return false;
        if (due_card(pocket_unpack_card(packed), day)) ++waiting;
    }
    /* Keep all historical counters and obligations. A very long-lived task
       can exceed this checkpoint's unique-count bound when several days are
       admitted into it. Fail the candidate transaction rather than truncate
       reviews, overflow uint16_t, or reset completed counts silently. */
    uint32_t loaded = (uint32_t)b->review_done + active_review;
    uint32_t total = loaded + waiting;
    if (loaded > UINT16_MAX || total > UINT16_MAX ||
        total + (uint32_t)b->new_total > POCKET_WORD_COUNT) return false;
    b->selection_day = day;
    b->review_loaded = (uint16_t)loaded;
    b->review_total = (uint16_t)total;
    b->review_cursor = 0;
    const unsigned old_length = b->length;
    if (!fill(s, read, ctx)) return false;
    /* Calendar admission alone gives newly loaded reviews priority after the
       current head. All old tokens retain their relative order, including
       incomplete seven-round/partial reinforcement. Normal same-day fill
       retains its established append behavior. A full cache refills later. */
    pocket_token_t admitted[POCKET_ACTIVE_MAX];
    unsigned count = 0;
    for (unsigned i = old_length; i < b->length; ++i) {
        pocket_token_t t = b->queue[i];
        if (!pocket_unpack_card(b->active[t.slot].packed).learned) break;
        admitted[count++] = t;
    }
    if (count) {
        memmove(b->queue + 1u + count, b->queue + 1u,
                (old_length - 1u) * sizeof(b->queue[0]));
        memcpy(b->queue + 1u, admitted, count * sizeof(b->queue[0]));
    }
    return true;
}
bool pocket_word_start(pocket_word_state_t *s, uint32_t day, pocket_word_read_fn read, void *ctx) {
    if (day < 18000 || day > 50000 || day < s->body.day) return false;
    s->changed_word = POCKET_NO_WORD; s->changed_card = 0;
    if (s->body.length) return pocket_word_refresh_due(s, day, read, ctx);
    memset(&s->body, 0, sizeof(s->body));
    pocket_word_body_t *b = &s->body; b->day = b->selection_day = day;
    s->can_undo = 0;
    unsigned lesson = POCKET_LESSON_COUNT;
    for (unsigned i = 0; i < POCKET_WORD_COUNT; ++i) {
        uint32_t packed;
        if (!read_card(read, ctx, i, &packed)) return false;
        pocket_card_t c = pocket_unpack_card(packed);
        if (c.familiar) { ++b->total_familiar; continue; }
        if (c.learned && !c.level) {
            if (!(packed & POCKET_IMPORTED_KNOWN)) ++b->total_first_known;
            continue;
        }
        if (due_card(c, day)) ++b->review_total;
        if (!c.learned) {
            if (lesson == POCKET_LESSON_COUNT) lesson = i / POCKET_LESSON_SIZE;
            if (i / POCKET_LESSON_SIZE == lesson) ++b->new_total;
        }
    }
    if (b->new_total) {
        b->lesson = lesson + 1; b->new_cursor = lesson * POCKET_LESSON_SIZE;
        unsigned end = (lesson + 1) * POCKET_LESSON_SIZE;
        b->new_end = end < POCKET_WORD_COUNT ? end : POCKET_WORD_COUNT;
    }
    return fill(s, read, ctx);
}
static void erase_token(pocket_word_body_t *b, unsigned i) {
    --b->length;
    memmove(&b->queue[i], &b->queue[i + 1], (b->length - i) * sizeof(b->queue[0]));
    memset(&b->queue[b->length], 0, sizeof(b->queue[0]));
}
static void insert_token(pocket_word_body_t *b, unsigned i, pocket_token_t t) {
    if (i > b->length) i = b->length;
    memmove(&b->queue[i + 1], &b->queue[i], (b->length - i) * sizeof(b->queue[0]));
    b->queue[i] = t; ++b->length;
}
static void purge(pocket_word_body_t *b, unsigned slot) {
    for (unsigned i = 0; i < b->length;)
        if (b->queue[i].slot == slot) erase_token(b, i); else ++i;
}
static void save_undo(pocket_word_state_t *s, const pocket_word_cached_t *a) {
    s->undo = s->body; s->undo_word = a->word; s->undo_card = a->packed; s->can_undo = 1;
}
/* Locate a real gap of three distinct other words. Repeated reinforcement
 * tokens for one other word do not count as three words. */
static unsigned gap_position(const pocket_word_body_t *b, unsigned slot) {
    bool seen[POCKET_ACTIVE_MAX] = {false}; unsigned distinct = 0;
    for (unsigned i = 0; i < b->length; ++i) {
        unsigned other = b->queue[i].slot;
        if (other != slot && !seen[other]) {
            seen[other] = true;
            if (++distinct == POCKET_WORD_PARTIAL_GAP) return i + 1;
        }
    }
    return b->length;
}
/* Partial knowledge during full reinforcement is not a successful stage.
 * Preserve every outstanding stage and their order, delaying the first one
 * behind the available other words without inserting extra obligations. */
static void delay_reinforcement(pocket_word_body_t *b, unsigned slot) {
    pocket_token_t pending[7]; unsigned positions[7], count = 0, others = 0;
    for (unsigned i = 0; i < b->length; ++i) {
        if (b->queue[i].slot == slot) {
            pending[count] = b->queue[i]; positions[count++] = others;
        } else ++others;
    }
    purge(b, slot);
    unsigned gap = gap_position(b, slot), base = b->length;
    for (unsigned i = 0; i < count; ++i) {
        unsigned position = positions[i] > gap + i ? positions[i] : gap + i;
        insert_token(b, (position < base ? position : base) + i, pending[i]);
    }
}
bool pocket_word_answer(pocket_word_state_t *s, pocket_word_answer_t answer, pocket_word_read_fn read, void *ctx) {
    pocket_word_body_t *b = &s->body;
    if (!b->length || answer < POCKET_WORD_CORRECT || answer > POCKET_WORD_PARTIAL) return false;
    const unsigned slot = b->queue[0].slot;
    pocket_word_cached_t *a = &b->active[slot];
    pocket_card_t c = pocket_unpack_card(a->packed);
    const bool was_learned = c.learned;
    const bool first = answer == POCKET_WORD_CORRECT && !c.learned && !c.level && !a->failed_round && !b->queue[0].stage;
    s->changed_word = POCKET_NO_WORD; s->changed_card = 0;
    s->can_undo = 0;
    if (first || answer == POCKET_WORD_FAMILIAR) save_undo(s, a);
    if (answer == POCKET_WORD_PARTIAL) {
        if (a->failed_round == 1) {
            delay_reinforcement(b, slot);
            return true;
        }
        purge(b, slot);
        if (!c.level) c.level = 1;
        c.due_day = b->day + 1;
        a->packed = pocket_pack_card(c) | POCKET_WORD_PARTIAL_PENDING;
        a->failed_round = 2;
        insert_token(b, gap_position(b, slot), (pocket_token_t){slot, 0});
        s->changed_word = a->word; s->changed_card = a->packed;
        return true;
    }
    if (answer == POCKET_WORD_FAMILIAR) {
        c.familiar = 1; ++b->skipped; ++b->total_familiar; purge(b, slot);
    } else {
        erase_token(b, 0);
        if (answer == POCKET_WORD_WRONG) {
            static const unsigned positions[] = {1, 3, 6, 11, 18, 30, 48};
            purge(b, slot);
            if (b->length + 7u > POCKET_QUEUE_MAX) return false;
            const unsigned base = b->length;
            c.level = 1; c.due_day = b->day + 1; a->failed_round = 1;
            for (unsigned i = 0; i < 7; ++i)
                insert_token(b, (positions[i] < base ? positions[i] : base) + i, (pocket_token_t){slot, i + 1});
            for (unsigned i = 0; i + 1 < b->length; ++i) {
                if (b->queue[i].slot != b->queue[i + 1].slot) continue;
                for (unsigned j = i + 2; j < b->length; ++j) {
                    if (b->queue[j].slot == b->queue[i].slot) continue;
                    pocket_token_t t = b->queue[j]; erase_token(b, j); insert_token(b, i + 1, t); break;
                }
            }
            a->packed = pocket_pack_card(c);
            s->changed_word = a->word; s->changed_card = a->packed;
            return true;
        }
        for (unsigned i = 0; i < b->length; ++i) if (b->queue[i].slot == slot) return true;
        if (first) {
            c.learned = 1; c.due_day = UINT32_MAX;
            ++b->first_known; ++b->total_first_known;
        } else if (a->failed_round == 2) {
            /* Completion of this task's repair is not level advancement.
             * Persist the flag so tomorrow's whole-word check is explicit. */
            c.learned = 1;
            c.due_day = b->day + 1;
        } else {
            if (!c.learned) { c.learned = 1; c.level = 1; }
            else if (!a->failed_round && c.level < POCKET_MAX_LEVEL) ++c.level;
            c.due_day = b->day + pocket_review_interval_days(c.level);
        }
        ++b->completed;
    }
    s->changed_word = a->word; s->changed_card = pocket_pack_card(c);
    if (answer != POCKET_WORD_FAMILIAR && a->failed_round == 2)
        s->changed_card |= POCKET_WORD_PARTIAL_PENDING;
    if (was_learned) ++b->review_done; else ++b->new_done;
    memset(a, 0, sizeof(*a));
    return fill(s, read, ctx);
}
bool pocket_word_undo(pocket_word_state_t *s) {
    if (!s->can_undo) return false;
    uint32_t day = s->body.day; s->body = s->undo; s->body.day = day;
    s->changed_word = s->undo_word; s->changed_card = s->undo_card;
    s->can_undo = 0;
    return true;
}
bool pocket_word_commit(pocket_word_state_t *live, pocket_word_state_t *next, pocket_word_store_fn store, void *ctx) {
    next->revision = live->revision + 1; pocket_word_seal(next);
    if (!pocket_word_valid(next) || !store(next, sizeof(*next), next->changed_word, next->changed_card, ctx)) return false;
    *live = *next; return true;
}
uint16_t pocket_word_current_word(const pocket_word_state_t *s) {
    return s->body.length ? s->body.active[s->body.queue[0].slot].word : POCKET_NO_WORD;
}
pocket_card_t pocket_word_current_card(const pocket_word_state_t *s) {
    if (!s->body.length) return (pocket_card_t){0};
    const pocket_word_cached_t *a = &s->body.active[s->body.queue[0].slot];
    pocket_card_t c = pocket_unpack_card(a->packed); c.failed_round = a->failed_round; return c;
}
bool pocket_word_current_partial(const pocket_word_state_t *s) {
    return s->body.length &&
        (s->body.active[s->body.queue[0].slot].packed & POCKET_WORD_PARTIAL_PENDING);
}
uint16_t pocket_word_partial_gap(const pocket_word_state_t *s, uint16_t word) {
    bool seen[POCKET_ACTIVE_MAX] = {false}; uint16_t distinct = 0;
    for (unsigned i = 0; i < s->body.length; ++i) {
        unsigned slot = s->body.queue[i].slot;
        if (s->body.active[slot].word == word) return distinct;
        if (!seen[slot]) {
            seen[slot] = true;
            if (distinct < POCKET_WORD_PARTIAL_GAP) ++distinct;
        }
    }
    return 0;
}
uint16_t pocket_word_remaining(const pocket_word_state_t *s) { return s->body.length; }
uint16_t pocket_word_new_remaining(const pocket_word_state_t *s) { return s->body.new_total - s->body.new_done; }
uint16_t pocket_word_review_remaining(const pocket_word_state_t *s) { return s->body.review_total - s->body.review_done; }
uint16_t pocket_word_unique_remaining(const pocket_word_state_t *s) { return pocket_word_new_remaining(s) + pocket_word_review_remaining(s); }
uint16_t pocket_word_group_size(const pocket_word_state_t *s) { return s->body.new_total + s->body.review_total; }
uint16_t pocket_word_familiar_count(const pocket_word_state_t *s) { return s->body.total_familiar; }
uint16_t pocket_word_first_known_count(const pocket_word_state_t *s) { return s->body.total_first_known; }
