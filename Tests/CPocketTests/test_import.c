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
int main(void) {
    test_import_preserves_every_value_and_emits_no_history();
    test_pending_new_and_review_bridge(); test_invalid_inputs_fail_closed();
    test_pending_repair_does_not_promote_same_day();
    test_blank_behavior_is_unchanged();
    puts("PASS all synthetic CPocket migration constructor tests"); return 0;
}
