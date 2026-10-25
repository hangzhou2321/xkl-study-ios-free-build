#include "xkl_engine.h"
#include "pocket_word_model.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* All fixtures are synthetic. No user state image is read. */
static const uint8_t stream[16] = {1, 3, 5, 7, 9, 11, 13, 15, 2, 4, 6, 8, 10, 12, 14, 16};
static xkl_info_t info(xkl_engine_t *e) {
    xkl_info_t result; assert(xkl_engine_info(e, &result)); return result;
}
static uint32_t progress(unsigned level, uint32_t due) {
    pocket_card_t card = {.due_day = due, .level = (uint8_t)level, .learned = 1};
    return pocket_pack_card(card);
}
static xkl_engine_t *restored(xkl_engine_t *e) {
    size_t count = xkl_engine_snapshot_size(e); assert(count);
    uint8_t *bytes = malloc(count); assert(bytes);
    assert(xkl_engine_snapshot(e, bytes, count) == count);
    xkl_engine_t *copy = xkl_engine_restore(bytes, count); assert(copy);
    free(bytes); return copy;
}
static void test_import_preserves_every_value_and_emits_no_history(void) {
    uint32_t cards[30] = {0};
    cards[0] = progress(1, 20740); cards[2] = progress(10, 20900);
    cards[29] = progress(3, 20780) | POCKET_WORD_PARTIAL_PENDING;
    uint32_t original[30]; memcpy(original, cards, sizeof(cards));
    xkl_engine_t *e = xkl_engine_import_cards(30, cards, 20750, XKL_NO_WORD, stream); assert(e);
    xkl_info_t initial = info(e);
    assert(initial.log_records == 0 && !initial.has_task && !initial.revealed);
    assert(initial.day == 20750 && initial.selection_day == 20750);
    assert(initial.completed == 0 && initial.first_known == 0 && initial.familiar == 0);
    for (unsigned i = 0; i < 30; ++i) assert(xkl_engine_card(e, i) == cards[i]);
    for (unsigned i = 30; i < XKL_WORD_COUNT; ++i) {
        uint32_t packed = xkl_engine_card(e, i);
        assert(packed & POCKET_IMPORTED_KNOWN);
        assert(pocket_unpack_card(packed).due_day == UINT32_MAX);
    }
    assert(!memcmp(original, cards, sizeof(cards)));
    xkl_engine_t *copy = restored(e);
    assert(info(copy).log_records == 0);
    assert(xkl_engine_start(copy, 20750, 1));
    assert(info(copy).word == 0 && info(copy).review_remaining == 1);
    assert(info(copy).new_remaining == 23); /* Original 25-slot first lesson. */
    assert(xkl_engine_reveal(copy, 2));
    assert(xkl_engine_answer(copy, 0, 3));
    assert(xkl_engine_card(e, 0) == cards[0]); /* Separate instance unchanged. */
    assert(xkl_engine_card(copy, 0) == progress(2, 20752));
    xkl_engine_free(copy); xkl_engine_free(e);
    puts("PASS import: exact card/due preservation, zero invented history, inert slots, restore, ordinary due/new admission and instance isolation");
}
static void test_pending_new_and_review_bridge(void) {
    for (unsigned learned = 0; learned < 2; ++learned) {
        uint32_t cards[30] = {0};
        if (learned) cards[29] = progress(4, 20800); /* Future due still preserved. */
        uint32_t before = cards[29];
        xkl_engine_t *e = xkl_engine_import_cards(30, cards, 20750, 29, stream); assert(e);
        xkl_info_t initial = info(e);
        assert(initial.word == 29 && initial.has_task && initial.total_remaining == 1);
        assert(initial.log_records == 0 && !initial.revealed && initial.completed == 0);
        assert(initial.new_remaining == !learned && initial.review_remaining == learned);
        assert(xkl_engine_card(e, 29) == before);
        xkl_engine_t *copy = restored(e); xkl_engine_free(e); e = copy;
        assert(xkl_engine_start(e, 20750, 1));
        assert(info(e).word == 29 && info(e).stage == 0 && !info(e).revealed);
        assert(!xkl_engine_answer(e, 0, 2));
        assert(xkl_engine_reveal(e, 3)); assert(xkl_engine_answer(e, 1, 4));
        assert(xkl_engine_current_repeats(e) == 7);
        int64_t clock = 5;
        for (unsigned stage = 1; stage <= 7; ++stage) {
            assert(info(e).word == 29 && info(e).stage == stage);
            assert(xkl_engine_reveal(e, ++clock)); assert(xkl_engine_answer(e, 0, ++clock));
        }
        assert(!info(e).has_task && info(e).completed == 1);
        assert(xkl_engine_card(e, 29) == progress(1, 20751));
        assert(xkl_engine_start(e, 20750, ++clock));
        assert(info(e).word == 0 && info(e).new_remaining == 25);
        assert(info(e).review_remaining == 0);
        xkl_engine_free(e);
    }
    puts("PASS imported pending new/review presentation: no grade until reveal, unchanged seven-stage recovery, then original task selection");
}
static void test_pending_repair_does_not_promote_same_day(void) {
    uint32_t packed = progress(1, 20751) | POCKET_WORD_PARTIAL_PENDING;
    xkl_engine_t *e = xkl_engine_import_cards(1, &packed, 20750, 0, stream); assert(e);
    assert(xkl_engine_card(e, 0) == packed && info(e).log_records == 0);
    assert(xkl_engine_start(e, 20750, 1));
    assert(xkl_engine_reveal(e, 2)); assert(xkl_engine_answer(e, 0, 3));
    assert(xkl_engine_card(e, 0) == packed);
    assert(xkl_engine_start(e, 20751, 4));
    assert(xkl_engine_reveal(e, 5)); assert(xkl_engine_answer(e, 0, 6));
    assert(xkl_engine_card(e, 0) == progress(2, 20753));
    xkl_engine_free(e);
    puts("PASS imported pending repair keeps tomorrow obligation; next-day recall advances normally");
}
static void test_invalid_inputs_fail_closed(void) {
    uint32_t card = 0;
    uint8_t zero[16] = {0};
    assert(!xkl_engine_import_cards(0, &card, 20750, XKL_NO_WORD, stream));
    assert(!xkl_engine_import_cards(XKL_WORD_COUNT + 1, &card, 20750, XKL_NO_WORD, stream));
    assert(!xkl_engine_import_cards(1, NULL, 20750, XKL_NO_WORD, stream));
    assert(!xkl_engine_import_cards(1, &card, 17999, XKL_NO_WORD, stream));
    assert(!xkl_engine_import_cards(1, &card, 50001, XKL_NO_WORD, stream));
    assert(!xkl_engine_import_cards(1, &card, 20750, 1, stream));
    assert(!xkl_engine_import_cards(1, &card, 20750, XKL_NO_WORD, zero));
    assert(!xkl_engine_import_cards(1, &card, 20750, XKL_NO_WORD, NULL));
    uint32_t bad[] = {UINT32_MAX, 1u << 24, 11u << 16, 1u << 16,
        1u << 20, POCKET_WORD_PARTIAL_PENDING, POCKET_IMPORTED_KNOWN};
    for (unsigned i = 0; i < sizeof(bad) / sizeof(*bad); ++i)
        assert(!xkl_engine_import_cards(1, &bad[i], 20750, XKL_NO_WORD, stream));
    card = (1u << 20) | UINT16_MAX;
    assert(!xkl_engine_import_cards(1, &card, 20750, 0, stream));
    card = 1u << 21;
    assert(!xkl_engine_import_cards(1, &card, 20750, 0, stream));
    puts("PASS invalid import count, date, pointer, stream, packed state and pending completed/familiar cards rejected");
}
static void test_blank_behavior_is_unchanged(void) {
    xkl_engine_t *e = xkl_engine_blank(30, stream); assert(e);
    assert(info(e).log_records == 0 && !info(e).has_task);
    assert(info(e).day == POCKET_INITIAL_DAY);
    for (unsigned i = 0; i < 30; ++i) assert(xkl_engine_card(e, i) == 0);
    assert(xkl_engine_start(e, 20750, 1));
    assert(info(e).word == 0 && info(e).new_remaining == 25);
    assert(xkl_engine_reveal(e, 2)); assert(xkl_engine_answer(e, 0, 3));
    assert(xkl_engine_card(e, 0) == 0x10ffffu && info(e).first_known == 1);
    xkl_engine_free(e);
    puts("PASS unchanged blank collection: original lesson size and first-correct completion");
}
static uint8_t *snapshot_bytes(xkl_engine_t *e, size_t *count) {
    *count = xkl_engine_snapshot_size(e); assert(*count);
    uint8_t *bytes = malloc(*count); assert(bytes);
    assert(xkl_engine_snapshot(e, bytes, *count) == *count); return bytes;
}
static pocket_state_t checkpoint(xkl_engine_t *e) {
    size_t count; uint8_t *bytes = snapshot_bytes(e, &count);
    pocket_state_t state; memcpy(&state, bytes + 96, sizeof(state)); free(bytes);
    assert(pocket_word_valid(&state)); return state;
}
static void assert_snapshot_equal(xkl_engine_t *e, const uint8_t *bytes, size_t size) {
    size_t count; uint8_t *current = snapshot_bytes(e, &count);
    assert(count == size && !memcmp(current, bytes, size)); free(current);
}
static void assert_metadata_only_since(xkl_engine_t *e, uint32_t sequence) {
    for (uint32_t index = sequence; index < info(e).log_records; ++index) {
        xkl_event_info_t event; assert(xkl_engine_event(e, index, &event));
        assert(event.kind >= 1 && event.kind <= 4);
    }
}
static void test_collection_append_filters_only_removed_tokens_and_preserves_reveal(void) {
    xkl_engine_t *e = xkl_engine_blank(35, stream); assert(e);
    assert(xkl_engine_start(e, 20750, 10)); assert(xkl_engine_reveal(e, 11)); assert(xkl_engine_answer(e, 1, 12));
    assert(xkl_engine_reveal(e, 13));
    xkl_info_t before = info(e); pocket_state_t old = checkpoint(e);
    assert(before.word == 1 && before.revealed);
    uint32_t values[37]; uint8_t enabled[37]; memset(enabled, 1, sizeof(enabled));
    for (unsigned i = 0; i < 35; ++i) values[i] = xkl_engine_card(e, i);
    values[35] = progress(2, 20750); values[36] = 0; enabled[5] = 0;
    size_t prefix_count = xkl_engine_log_size(e); uint8_t *prefix = malloc(prefix_count); assert(prefix);
    assert(xkl_engine_log(e, prefix, prefix_count) == prefix_count);
    assert(xkl_engine_reconcile_collection(e, 35, 37, enabled, values, 14, NULL, NULL));
    xkl_info_t after = info(e); pocket_state_t changed = checkpoint(e);
    assert(after.word == before.word && after.revealed && after.stage == before.stage);
    assert(after.completed == before.completed && changed.body.new_done == old.body.new_done);
    unsigned at = 0, wrong_stages = 0;
    for (unsigned i = 0; i < old.body.length; ++i) {
        pocket_token_t token = old.body.queue[i]; uint16_t word = old.body.active[token.slot].word;
        if (word == 5) continue;
        pocket_token_t current = changed.body.queue[at++];
        assert(changed.body.active[current.slot].word == word && current.stage == token.stage);
        if (word == 0) ++wrong_stages;
    }
    assert(at == changed.body.length && wrong_stages == 7);
    for (unsigned i = 0; i < 35; ++i) if (i != 5) assert(xkl_engine_card(e, i) == values[i]);
    assert(xkl_engine_card(e, 5) & POCKET_IMPORTED_KNOWN);
    assert(xkl_engine_card(e, 35) == values[35] && xkl_engine_card(e, 36) == 0);
    assert_metadata_only_since(e, before.log_records);
    size_t full_count = xkl_engine_log_size(e); uint8_t *full = malloc(full_count); assert(full);
    assert(xkl_engine_log(e, full, full_count) == full_count && !memcmp(prefix, full, prefix_count));
    free(full); free(prefix);
    xkl_engine_t *copy = restored(e); xkl_engine_free(e); e = copy;
    size_t size; uint8_t *bytes = snapshot_bytes(e, &size);
    assert(xkl_engine_reconcile_collection(e, 37, 37, enabled, values, 15, NULL, NULL));
    assert_snapshot_equal(e, bytes, size); free(bytes);
    assert(xkl_engine_answer(e, 0, 16)); /* The retained reveal remains usable. */
    int64_t clock = 20; bool admitted = false; unsigned guard = 0;
    while (info(e).has_task) {
        assert(++guard < 100); assert(info(e).word != 5);
        if (info(e).word == 35) admitted = true;
        assert(xkl_engine_reveal(e, ++clock)); assert(xkl_engine_answer(e, 0, ++clock));
    }
    assert(admitted && xkl_engine_card(e, 35) == progress(3, 20753));
    xkl_engine_free(e);
    puts("PASS collection append: stable IDs, only disabled tokens removed, seven stages retained, revealed head, old log prefix, no-op idempotence and later due refill");
}
static void test_collection_parking_head_reactivation_and_all_disabled(void) {
    uint32_t original[4] = {progress(3, 20800), 0, 0, 0};
    xkl_engine_t *e = xkl_engine_import_cards(4, original, 20750, 0, stream); assert(e);
    assert(xkl_engine_start(e, 20750, 10)); assert(xkl_engine_reveal(e, 11));
    uint8_t enabled[4] = {0, 1, 1, 1}; uint32_t before = info(e).log_records;
    assert(xkl_engine_reconcile_collection(e, 4, 4, enabled, original, 12, NULL, NULL));
    assert(!info(e).has_task && !info(e).revealed && info(e).completed == 0);
    assert_metadata_only_since(e, before);
    assert(xkl_engine_card(e, 0) & POCKET_IMPORTED_KNOWN);
    enabled[0] = 1;
    assert(xkl_engine_reconcile_collection(e, 4, 4, enabled, original, 13, NULL, NULL));
    assert(xkl_engine_card(e, 0) == original[0]); /* Exact parked due/level reactivated. */
    assert(xkl_engine_start(e, 20750, 14));
    assert(info(e).word == 1 && !info(e).revealed);
    assert(xkl_engine_reveal(e, 15));
    enabled[1] = 0; before = info(e).log_records;
    assert(xkl_engine_reconcile_collection(e, 4, 4, enabled, original, 16, NULL, NULL));
    assert(info(e).word == 2 && !info(e).revealed && info(e).completed == 0);
    assert_metadata_only_since(e, before);
    memset(enabled, 0, sizeof(enabled));
    assert(xkl_engine_reconcile_collection(e, 4, 4, enabled, original, 17, NULL, NULL));
    assert(!info(e).has_task && !info(e).revealed && info(e).completed == 0);
    xkl_engine_t *copy = restored(e); xkl_engine_free(e); e = copy;
    assert(xkl_engine_start(e, 20750, 18)); assert(!info(e).has_task);
    xkl_engine_free(e);
    puts("PASS collection parking: removed revealed head never grades, replacement head hidden, exact due reactivation and empty scope survives restore");
}
static void test_collection_invalid_failure_is_atomic_and_cold_clock_rebases(void) {
    xkl_engine_t *e = xkl_engine_blank(3, stream); assert(e);
    assert(xkl_engine_start(e, 20750, 100)); assert(xkl_engine_reveal(e, 101)); assert(xkl_engine_answer(e, 1, 102));
    uint8_t enabled[4] = {1, 1, 1, 1}; uint32_t values[4];
    for (unsigned i = 0; i < 3; ++i) values[i] = xkl_engine_card(e, i);
    values[3] = 0;
    size_t size; uint8_t *bytes = snapshot_bytes(e, &size);
    uint32_t old = values[0]; values[0] = 0;
    assert(!xkl_engine_reconcile_collection(e, 3, 4, enabled, values, 103, NULL, NULL)); assert_snapshot_equal(e, bytes, size); values[0] = old;
    enabled[1] = 2; assert(!xkl_engine_reconcile_collection(e, 3, 4, enabled, values, 103, NULL, NULL)); assert_snapshot_equal(e, bytes, size); enabled[1] = 1;
    values[3] = UINT32_MAX; assert(!xkl_engine_reconcile_collection(e, 3, 4, enabled, values, 103, NULL, NULL)); assert_snapshot_equal(e, bytes, size); values[3] = 0;
    assert(!xkl_engine_reconcile_collection(e, 3, 2, enabled, values, 103, NULL, NULL)); assert_snapshot_equal(e, bytes, size);
    assert(!xkl_engine_reconcile_collection(e, 3, 4, enabled, values, -1, NULL, NULL)); assert_snapshot_equal(e, bytes, size);
    assert(!xkl_engine_reconcile_collection(e, 3, 4, NULL, values, 103, NULL, NULL)); assert_snapshot_equal(e, bytes, size);
    assert(!xkl_engine_reconcile_collection(e, 3, 4, enabled, NULL, 103, NULL, NULL)); assert_snapshot_equal(e, bytes, size);
    free(bytes);
    assert(xkl_engine_reveal(e, 104)); uint32_t head = info(e).word, before = info(e).log_records;
    assert(xkl_engine_reconcile_collection(e, 3, 4, enabled, values, 1, NULL, NULL));
    assert(info(e).word == head && info(e).revealed); assert_metadata_only_since(e, before);
    xkl_engine_t *copy = restored(e); xkl_engine_free(e); e = copy;
    assert(xkl_engine_answer(e, 0, 2)); xkl_engine_free(e);
    e = xkl_engine_blank(3, stream); assert(e);
    uint32_t fresh[4] = {0}; assert(xkl_engine_reconcile_collection(e, 3, 4, enabled, fresh, 1, NULL, NULL));
    assert(!info(e).has_task); assert_metadata_only_since(e, 0);
    assert(xkl_engine_start(e, 20750, 2)); assert(info(e).has_task && info(e).word == 0);
    copy = restored(e); xkl_engine_free(copy); xkl_engine_free(e);
    puts("PASS collection invalid-input atomic rollback, monotonic-clock rebase and never-started collection initialization without grades");
}
static void test_collection_transfers_pending_stages_and_rejects_capacity_loss(void) {
    xkl_engine_t *source = xkl_engine_blank(8, stream); assert(source);
    int64_t clock = 1; assert(xkl_engine_start(source, 20750, clock));
    assert(xkl_engine_reveal(source, ++clock)); assert(xkl_engine_answer(source, 1, ++clock));
    while (info(source).word != 0) {
        assert(xkl_engine_reveal(source, ++clock)); assert(xkl_engine_answer(source, 0, ++clock));
    }
    assert(info(source).stage == 1);
    assert(xkl_engine_reveal(source, ++clock)); assert(xkl_engine_answer(source, 0, ++clock));
    uint32_t failed, mask = xkl_engine_pending_stages(source, 0, &failed);
    assert(mask == 0xfcu && failed == 1);
    uint32_t packed = xkl_engine_card(source, 0);
    xkl_engine_t *destination = xkl_engine_blank(3, stream); assert(destination);
    assert(xkl_engine_start(destination, 20750, ++clock));
    assert(xkl_engine_reveal(destination, ++clock)); assert(xkl_engine_answer(destination, 0, ++clock));
    uint32_t values[4]; uint8_t enabled[4] = {1, 1, 1, 1}, stages[4] = {0, 0, 0, (uint8_t)mask}, failures[4] = {0, 0, 0, (uint8_t)failed};
    for (unsigned i = 0; i < 3; ++i) values[i] = xkl_engine_card(destination, i);
    values[3] = packed; uint32_t before = info(destination).log_records;
    assert(xkl_engine_reconcile_collection(destination, 3, 4, enabled, values, ++clock, stages, failures));
    assert(xkl_engine_pending_stages(destination, 3, &failed) == mask && failed == 1);
    assert(xkl_engine_card(destination, 3) == packed);
    assert_metadata_only_since(destination, before);
    xkl_engine_t *copy = restored(destination); xkl_engine_free(destination); destination = copy;
    assert(xkl_engine_pending_stages(destination, 3, &failed) == mask && failed == 1);
    enabled[3] = 0;
    assert(xkl_engine_reconcile_collection(destination, 4, 4, enabled, values, ++clock, NULL, NULL));
    assert(xkl_engine_pending_stages(destination, 3, &failed) == 0 && failed == 0);
    enabled[3] = 1;
    assert(xkl_engine_reconcile_collection(destination, 4, 4, enabled, values, ++clock, stages, failures));
    assert(xkl_engine_pending_stages(destination, 3, &failed) == mask && failed == 1);
    assert(xkl_engine_card(destination, 3) == packed);
    unsigned observed = 0;
    while (info(destination).has_task) {
        if (info(destination).word == 3) assert(info(destination).stage == ++observed + 1);
        assert(xkl_engine_reveal(destination, ++clock)); assert(xkl_engine_answer(destination, 0, ++clock));
    }
    assert(observed == 6 && xkl_engine_card(destination, 3) == progress(1, 20751));
    xkl_engine_free(destination);

    destination = xkl_engine_blank(25, stream); assert(destination); assert(xkl_engine_start(destination, 20750, ++clock));
    uint8_t crowded_enabled[26], crowded_stages[26] = {0}, crowded_failed[26] = {0}; uint32_t crowded_values[26] = {0};
    memset(crowded_enabled, 1, sizeof(crowded_enabled));
    crowded_values[25] = packed; crowded_stages[25] = (uint8_t)mask; crowded_failed[25] = 1;
    size_t size; uint8_t *bytes = snapshot_bytes(destination, &size);
    assert(!xkl_engine_reconcile_collection(destination, 25, 26, crowded_enabled, crowded_values, ++clock, crowded_stages, crowded_failed));
    assert_snapshot_equal(destination, bytes, size); free(bytes);
    xkl_engine_free(destination);

    /* A new destination can use an explicit empty inert snapshot and import
       its real obligations, without making 25 artificial fresh selections. */
    uint32_t inert = (1u << 20) | POCKET_IMPORTED_KNOWN | UINT16_MAX;
    uint32_t initial[4] = {inert, inert, inert, inert};
    destination = xkl_engine_import_cards(4, initial, 20750, XKL_NO_WORD, stream); assert(destination);
    values[0] = values[1] = values[2] = 0;
    assert(xkl_engine_reconcile_collection(destination, 4, 4, enabled, values, ++clock, stages, failures));
    assert(info(destination).word == 3 && info(destination).stage == 2 && info(destination).completed == 0);
    assert(xkl_engine_pending_stages(destination, 3, &failed) == mask && failed == 1);
    assert_metadata_only_since(destination, 0);
    copy = restored(destination); xkl_engine_free(copy); xkl_engine_free(destination);
    destination = xkl_engine_import_cards(4, initial, 20750, XKL_NO_WORD, stream); assert(destination);
    values[3] = progress(4, 20800) | POCKET_WORD_PARTIAL_PENDING; stages[3] = 1; failures[3] = 2;
    size_t unchanged_size; uint8_t *unchanged = snapshot_bytes(destination, &unchanged_size);
    stages[3] = 3; /* A stage-0 token cannot coexist with W tokens. */
    assert(!xkl_engine_reconcile_collection(destination, 4, 4, enabled, values, ++clock, stages, failures));
    assert_snapshot_equal(destination, unchanged, unchanged_size); free(unchanged);
    stages[3] = 1;
    assert(xkl_engine_reconcile_collection(destination, 4, 4, enabled, values, ++clock, stages, failures));
    assert(xkl_engine_pending_stages(destination, 3, &failed) == 1 && failed == 2);
    assert(xkl_engine_reveal(destination, ++clock)); assert(xkl_engine_answer(destination, 0, ++clock));
    assert(xkl_engine_card(destination, 3) == (progress(4, 20751) | POCKET_WORD_PARTIAL_PENDING));
    xkl_engine_free(destination); xkl_engine_free(source);
    puts("PASS collection transfer: exact remaining W stages and failed flag across append/park/reactivate, capacity failure retains snapshot, inert fresh destination accepts real pending work");
}
static void test_cold_completed_task_admits_deferred_before_ordinary_new_lesson(void) {
    xkl_engine_t *e = xkl_engine_blank(50, stream); assert(e);
    int64_t clock = 100; assert(xkl_engine_start(e, 20750, clock));
    while (info(e).has_task) {
        assert(info(e).word < 25);
        assert(xkl_engine_reveal(e, ++clock)); assert(xkl_engine_answer(e, 0, ++clock));
    }
    assert(info(e).completed == 25); pocket_state_t old = checkpoint(e);
    assert(old.body.new_done == 25 && old.body.length == 0);
    uint32_t before = info(e).log_records;
    xkl_engine_t *copy = restored(e); xkl_engine_free(e); e = copy;
    uint8_t enabled[75], stages[75] = {0}, failed[75] = {0}; uint32_t values[75];
    memset(enabled, 1, sizeof(enabled));
    for (unsigned i = 0; i < 50; ++i) values[i] = xkl_engine_card(e, i);
    for (unsigned i = 50; i < 75; ++i) {
        values[i] = 20751u | (1u << 16); /* Unlearned card with a real W7 obligation. */
        stages[i] = 1u << 7; failed[i] = 1;
    }
    assert(xkl_engine_reconcile_collection(e, 50, 75, enabled, values, 1, stages, failed));
    assert(info(e).word == 50 && info(e).stage == 7 && info(e).new_remaining == 25);
    assert(info(e).completed == 0 && !info(e).revealed);
    for (unsigned i = 25; i < 50; ++i) assert(xkl_engine_pending_stages(e, i, NULL) == 0);
    assert_metadata_only_since(e, before);
    copy = restored(e); xkl_engine_free(e); e = copy;
    clock = 2; unsigned count = 0;
    while (info(e).has_task) {
        assert(info(e).word == 50 + count && info(e).stage == 7); ++count;
        assert(xkl_engine_reveal(e, ++clock)); assert(xkl_engine_answer(e, 0, ++clock));
    }
    assert(count == 25 && info(e).completed == 25);
    assert(xkl_engine_start(e, 20750, ++clock));
    assert(info(e).word == 25 && info(e).new_remaining == 25);
    xkl_engine_free(e);
    puts("PASS cold completed task: clock-only rebase restores all 25 deferred W7 cards before the ordinary next 25, with no fabricated grades");
}
int main(void) {
    test_import_preserves_every_value_and_emits_no_history();
    test_pending_new_and_review_bridge(); test_invalid_inputs_fail_closed();
    test_pending_repair_does_not_promote_same_day();
    test_blank_behavior_is_unchanged();
    test_collection_append_filters_only_removed_tokens_and_preserves_reveal();
    test_collection_parking_head_reactivation_and_all_disabled();
    test_collection_invalid_failure_is_atomic_and_cold_clock_rebases();
    test_collection_transfers_pending_stages_and_rejects_capacity_loss();
    test_cold_completed_task_admits_deferred_before_ordinary_new_lesson();
    puts("PASS all synthetic CPocket migration constructor tests"); return 0;
}
