#include "xkl_engine.h"
#include "pocket_word_model.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Synthetic question IDs only; never reads a dictionary or personal seed. */
#define EXAM_COUNT 832u
#define DAY 20745u
static const uint8_t stream_a[16] = {0x31, 0x42, 0x53, 0x64};
static const uint8_t stream_b[16] = {0x98, 0x87, 0x76, 0x65};

static xkl_info_t info(const xkl_engine_t *e) {
    xkl_info_t value;
    assert(xkl_engine_info(e, &value));
    return value;
}
static xkl_engine_t *blank(uint32_t count, const uint8_t *stream) {
    xkl_engine_t *e = xkl_engine_blank(count, stream);
    assert(e);
    return e;
}
static uint8_t *snapshot(const xkl_engine_t *e, size_t *size) {
    *size = xkl_engine_snapshot_size(e);
    assert(*size);
    uint8_t *bytes = malloc(*size);
    assert(bytes);
    assert(xkl_engine_snapshot(e, bytes, *size) == *size);
    return bytes;
}
static void grade(xkl_engine_t *e, int answer, int64_t *clock) {
    assert(info(e).has_task);
    assert(xkl_engine_reveal(e, ++*clock));
    assert(xkl_engine_answer(e, answer, ++*clock));
}
static void check_tail(const xkl_engine_t *e, uint32_t active) {
    for (uint32_t i = active; i < XKL_WORD_COUNT; ++i) {
        uint32_t packed = xkl_engine_card(e, i);
        pocket_card_t c = pocket_unpack_card(packed);
        assert(packed & POCKET_IMPORTED_KNOWN);
        assert(c.learned && !c.familiar && c.level == 0);
        assert(c.due_day == UINT32_MAX);
    }
}
static void test_blank_validation(void) {
    const uint8_t zero[16] = {0};
    assert(!xkl_engine_blank(0, stream_a));
    assert(!xkl_engine_blank(XKL_WORD_COUNT + 1u, stream_a));
    assert(!xkl_engine_blank(UINT32_MAX, stream_a));
    assert(!xkl_engine_blank(EXAM_COUNT, NULL));
    assert(!xkl_engine_blank(EXAM_COUNT, zero));
    const uint32_t counts[] = {1, EXAM_COUNT, XKL_WORD_COUNT};
    for (unsigned n = 0; n < sizeof(counts) / sizeof(counts[0]); ++n) {
        xkl_engine_t *e = blank(counts[n], stream_a);
        for (uint32_t i = 0; i < counts[n]; ++i)
            assert(xkl_engine_card(e, i) == 0);
        check_tail(e, counts[n]);
        assert(xkl_engine_start(e, DAY, 1));
        xkl_info_t s = info(e);
        assert(s.has_task && s.word < counts[n]);
        assert(s.first_known == 0 && s.familiar == 0);
        assert(s.new_remaining == (counts[n] < 25 ? counts[n] : 25));
        uint8_t identity[16];
        assert(xkl_engine_stream(e, identity));
        assert(!memcmp(identity, stream_a, sizeof(identity)));
        xkl_engine_free(e);
    }
    puts("PASS blank bounds, stream validation, inert tail and zero user counts");
}
static void test_all_first_known(void) {
    xkl_engine_t *e = blank(EXAM_COUNT, stream_a);
    unsigned char seen[EXAM_COUNT] = {0};
    int64_t clock = 10;
    uint32_t total = 0;
    for (uint32_t lesson = 1; lesson <= 34; ++lesson) {
        assert(xkl_engine_start(e, DAY, ++clock));
        const uint32_t expected = lesson == 34 ? 7 : 25;
        xkl_info_t s = info(e);
        assert(s.lesson == lesson && s.new_remaining == expected);
        assert(s.review_remaining == 0 && s.total_remaining == expected);
        uint32_t answered = 0;
        while (info(e).has_task) {
            s = info(e);
            assert(s.word < EXAM_COUNT);
            assert(s.word >= (lesson - 1u) * 25u);
            assert(s.word < (lesson - 1u) * 25u + expected);
            assert(!seen[s.word]);
            seen[s.word] = 1;
            grade(e, 0, &clock);
            assert(++answered <= expected);
            ++total;
        }
        assert(answered == expected);
        assert(info(e).first_known == total && info(e).familiar == 0);
    }
    assert(total == EXAM_COUNT);
    for (uint32_t i = 0; i < EXAM_COUNT; ++i) assert(seen[i] == 1);
    check_tail(e, EXAM_COUNT);
    size_t size;
    uint8_t *bytes = snapshot(e, &size);
    xkl_engine_t *restored = xkl_engine_restore(bytes, size);
    assert(restored);
    free(bytes);
    const uint32_t days[] = {DAY, DAY + 1, DAY + 180, DAY + 720};
    for (unsigned i = 0; i < sizeof(days) / sizeof(days[0]); ++i) {
        assert(xkl_engine_start(restored, days[i], ++clock));
        xkl_info_t s = info(restored);
        assert(!s.has_task && s.word == XKL_NO_WORD);
        assert(s.total_remaining == 0 && s.new_remaining == 0 && s.review_remaining == 0);
        assert(s.first_known == EXAM_COUNT && s.familiar == 0);
    }
    check_tail(restored, EXAM_COUNT);
    xkl_engine_free(restored);
    xkl_engine_free(e);
    puts("PASS all 832 first-known: 33 lessons of 25 plus 7; no later reappearance");
}
static void test_isolation_restore(void) {
    xkl_engine_t *a = blank(EXAM_COUNT, stream_a);
    xkl_engine_t *b = blank(2, stream_b);
    int64_t clock = 10;
    assert(xkl_engine_start(a, DAY, ++clock));
    assert(xkl_engine_start(b, DAY, 1));
    size_t b_size;
    uint8_t *before_b = snapshot(b, &b_size);
    uint32_t wrong = info(a).word;
    grade(a, 1, &clock);
    size_t after_size;
    uint8_t *after_b = snapshot(b, &after_size);
    assert(b_size == after_size && !memcmp(before_b, after_b, b_size));
    free(after_b);
    assert(xkl_engine_card(b, wrong) == 0);
    assert(xkl_engine_reveal(a, ++clock));
    size_t a_size;
    uint8_t *before_a = snapshot(a, &a_size);
    xkl_engine_t *restored = xkl_engine_restore(before_a, a_size);
    assert(restored && info(restored).revealed);
    uint8_t *roundtrip = snapshot(restored, &after_size);
    assert(a_size == after_size && !memcmp(before_a, roundtrip, a_size));
    free(roundtrip);
    assert(xkl_engine_answer(restored, 2, ++clock));
    assert(info(restored).familiar == 1);
    assert(info(a).familiar == 0 && info(a).revealed);
    assert(xkl_engine_undo(restored, ++clock));
    assert(info(restored).familiar == 0 && !info(restored).revealed);
    uint8_t identity[16];
    assert(xkl_engine_stream(restored, identity));
    assert(!memcmp(identity, stream_a, sizeof(identity)));
    assert(xkl_engine_stream(b, identity));
    assert(!memcmp(identity, stream_b, sizeof(identity)));
    assert(xkl_engine_start(restored, DAY, ++clock));
    assert(!info(restored).revealed);
    assert(!xkl_engine_answer(restored, 0, ++clock));
    assert(xkl_engine_card(restored, wrong) == xkl_engine_card(a, wrong));
    check_tail(restored, EXAM_COUNT);
    free(before_a);
    free(before_b);
    xkl_engine_free(restored);
    xkl_engine_free(a);
    xkl_engine_free(b);
    puts("PASS independent instances, exact save/restore, identity, familiar undo and reveal gate");
}
static void test_original_reinforcement_and_days(void) {
    xkl_engine_t *e = blank(25, stream_a);
    int64_t clock = 10;
    assert(xkl_engine_start(e, DAY, ++clock));
    uint32_t wrong = info(e).word;
    grade(e, 1, &clock);
    unsigned seen_stages = 0, total = 0;
    while (info(e).has_task) {
        xkl_info_t s = info(e);
        assert(s.word < 25);
        if (s.word == wrong) assert(s.stage == ++seen_stages);
        grade(e, 0, &clock);
        assert(++total <= 31);
    }
    assert(seen_stages == 7 && total == 31);
    assert(info(e).first_known == 24 && info(e).familiar == 0);
    pocket_card_t card = pocket_unpack_card(xkl_engine_card(e, wrong));
    assert(card.learned && card.level == 1 && card.due_day == DAY + 1);
    const unsigned gaps[] = {2, 3, 5, 7, 10, 15, 30, 90, 180, 180};
    for (unsigned j = 0; j < sizeof(gaps) / sizeof(gaps[0]); ++j) {
        uint32_t due = card.due_day;
        assert(xkl_engine_start(e, due, ++clock));
        xkl_info_t s = info(e);
        assert(s.word == wrong && s.review_remaining == 1 && s.new_remaining == 0);
        grade(e, 0, &clock);
        card = pocket_unpack_card(xkl_engine_card(e, wrong));
        assert(card.level == (j + 2u < 10u ? j + 2u : 10u));
        assert(card.due_day == due + gaps[j]);
        assert(!info(e).has_task);
    }
    assert(xkl_engine_start(e, card.due_day, ++clock));
    grade(e, 1, &clock);
    seen_stages = 0;
    while (info(e).has_task) {
        assert(info(e).word == wrong && info(e).stage == ++seen_stages);
        grade(e, 0, &clock);
        assert(seen_stages <= 7);
    }
    assert(seen_stages == 7);
    check_tail(e, 25);
    xkl_engine_free(e);
    puts("PASS original wrong restores seven stages; 1/2/3/5/7/10/15/30/90/180-day reviews");
}
static void test_uncapped_review(void) {
    xkl_engine_t *e = blank(51, stream_a);
    int64_t clock = 10;
    for (unsigned lesson = 0; lesson < 3; ++lesson) {
        assert(xkl_engine_start(e, DAY, ++clock));
        unsigned actions = 0;
        while (info(e).has_task) {
            xkl_info_t s = info(e);
            assert(s.word < 51);
            grade(e, xkl_engine_card(e, s.word) == 0 ? 1 : 0, &clock);
            assert(++actions <= 200);
        }
    }
    assert(xkl_engine_start(e, DAY + 1, ++clock));
    assert(info(e).review_remaining == 51 && info(e).new_remaining == 0);
    unsigned answered = 0;
    while (info(e).has_task) {
        assert(info(e).word < 51);
        grade(e, 0, &clock);
        assert(++answered <= 51);
    }
    assert(answered == 51);
    assert(info(e).first_known == 0 && info(e).familiar == 0);
    check_tail(e, 51);
    xkl_engine_free(e);
    puts("PASS 51 due questions in one task: review count is not capped at 25");
}
static pocket_word_state_t checkpoint(const xkl_engine_t *e) {
    size_t size;
    uint8_t *bytes = snapshot(e, &size);
    pocket_word_state_t state;
    assert(size > 96u + sizeof(state));
    memcpy(&state, bytes + 96u, sizeof(state));
    free(bytes);
    assert(pocket_word_valid(&state));
    return state;
}
static unsigned stages_for(const xkl_engine_t *e, uint32_t word, uint8_t *stages) {
    pocket_word_state_t s = checkpoint(e);
    unsigned count = 0;
    for (unsigned i = 0; i < s.body.length; ++i) {
        const pocket_token_t *token = &s.body.queue[i];
        if (s.body.active[token->slot].word == word && token->stage > 0) {
            if (stages) stages[count] = token->stage;
            ++count;
        }
    }
    return count;
}
static xkl_exam_result_t exam_grade(xkl_engine_t *e, int answer,
    uint32_t plan, int64_t *clock) {
    assert(xkl_engine_reveal(e, ++*clock));
    xkl_exam_result_t result;
    xkl_policy_result_t policy;
    assert(xkl_engine_answer_exam(e, answer, ++*clock, false, 1, plan, &policy, &result));
    assert(result.version == 1 && result.plan == plan);
    return result;
}
static void roundtrip(xkl_engine_t **engine) {
    size_t size, second_size;
    uint8_t *bytes = snapshot(*engine, &size);
    xkl_engine_t *restored = xkl_engine_restore(bytes, size);
    assert(restored);
    uint8_t *second = snapshot(restored, &second_size);
    assert(size == second_size && !memcmp(bytes, second, size));
    free(bytes);
    free(second);
    xkl_engine_free(*engine);
    *engine = restored;
}
static void test_exam_short_rewrong(void) {
    xkl_engine_t *e = blank(25, stream_a);
    int64_t clock = 10;
    assert(xkl_engine_start(e, DAY, ++clock));
    uint32_t word = info(e).word;
    xkl_exam_result_t result = exam_grade(e, 1, 1, &clock);
    assert(result.shortened_repeats == 4 && !result.tail_removed && !result.tail_deferred);
    uint8_t stages[7];
    assert(stages_for(e, word, stages) == 3);
    assert(stages[0] == 1 && stages[1] == 4 && stages[2] == 7);
    roundtrip(&e);
    while (info(e).word != word) exam_grade(e, 0, 0, &clock);
    assert(info(e).stage == 1 && xkl_engine_current_repeats(e) == 3);
    result = exam_grade(e, 0, 2, &clock);
    assert(!result.tail_removed && !result.tail_deferred);
    assert(stages_for(e, word, stages) == 2);
    assert(stages[0] == 4 && stages[1] == 7);
    while (info(e).word != word) exam_grade(e, 0, 0, &clock);
    assert(info(e).stage == 4 && xkl_engine_current_repeats(e) == 2);
    result = exam_grade(e, 1, 0, &clock);
    assert(!result.shortened_repeats && !result.tail_removed);
    assert(stages_for(e, word, stages) == 7);
    for (unsigned i = 0; i < 7; ++i) assert(stages[i] == i + 1);
    roundtrip(&e);
    unsigned repeats = 0, turns = 0;
    while (info(e).has_task) {
        if (info(e).word == word) {
            assert(info(e).stage == ++repeats);
            assert(xkl_engine_current_repeats(e) == 8u - repeats);
        }
        exam_grade(e, 0, 0, &clock);
        assert(++turns <= 40);
    }
    assert(repeats == 7 && xkl_engine_current_repeats(e) == 0);
    pocket_card_t c = pocket_unpack_card(xkl_engine_card(e, word));
    assert(c.level == 1 && c.due_day == DAY + 1);
    xkl_engine_free(e);
    puts("PASS exam first wrong keeps stages 1/4/7; repeat wrong restores 7; short snapshots restore");
}
static void test_exam_disabled_parity(void) {
    xkl_engine_t *original = blank(25, stream_a), *exam = blank(25, stream_a);
    int64_t clock = 10;
    assert(xkl_engine_start(original, DAY, clock));
    assert(xkl_engine_start(exam, DAY, clock));
    uint32_t target = info(original).word;
    unsigned turns = 0, repeats = 0;
    while (info(original).has_task) {
        assert(info(original).word == info(exam).word);
        assert(info(original).stage == info(exam).stage);
        if (turns && info(original).word == target) ++repeats;
        assert(xkl_engine_reveal(original, ++clock));
        assert(xkl_engine_reveal(exam, clock));
        int answer = turns == 0 ? 1 : 0;
        assert(xkl_engine_answer(original, answer, ++clock));
        xkl_exam_result_t result;
        assert(xkl_engine_answer_exam(exam, answer, clock, false, 0, 0, NULL, &result));
        assert(result.plan == 0 && !result.shortened_repeats && !result.tail_removed);
        size_t a_size, b_size;
        uint8_t *a = snapshot(original, &a_size), *b = snapshot(exam, &b_size);
        assert(a_size == b_size && !memcmp(a, b, a_size));
        free(a);
        free(b);
        assert(++turns <= 32);
    }
    assert(repeats == 7 && turns == 32);
    xkl_engine_free(original);
    xkl_engine_free(exam);
    puts("PASS disabled exam plan 0 equals original vocabulary entry byte-for-byte, seven repeats");
}
static void test_exam_short_tail_and_invalid_plans(void) {
    xkl_engine_t *e = blank(1, stream_a);
    int64_t clock = 10;
    assert(xkl_engine_start(e, DAY, ++clock));
    assert(xkl_engine_reveal(e, ++clock));
    size_t before_size, after_size;
    uint8_t *before = snapshot(e, &before_size);
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 1, NULL, NULL));
    assert(!xkl_engine_answer_exam(e, 1, ++clock, false, 1, 3, NULL, NULL));
    uint8_t *after = snapshot(e, &after_size);
    assert(before_size == after_size && !memcmp(before, after, before_size));
    free(before);
    free(after);
    xkl_exam_result_t result;
    assert(xkl_engine_answer_exam(e, 1, ++clock, false, 1, 1, NULL, &result));
    assert(result.shortened_repeats == 4 && xkl_engine_current_repeats(e) == 3);
    roundtrip(&e);
    uint32_t short_card = xkl_engine_card(e, 0);
    assert(xkl_engine_answer_exam(e, 2, ++clock, false, 1, 2, NULL, &result));
    assert(info(e).familiar == 1 && info(e).can_undo && !info(e).has_task);
    assert(!result.shortened_repeats && !result.tail_removed && !result.tail_deferred);
    assert(xkl_engine_undo(e, ++clock));
    assert(info(e).familiar == 0 && info(e).stage == 1 && !info(e).revealed);
    assert(xkl_engine_current_repeats(e) == 3 && xkl_engine_card(e, 0) == short_card);
    result = exam_grade(e, 0, 2, &clock);
    assert(result.tail_removed == 2 && result.tail_deferred == 1);
    assert(!info(e).has_task && info(e).first_known == 0 && info(e).familiar == 0);
    pocket_card_t c = pocket_unpack_card(xkl_engine_card(e, 0));
    assert(c.learned && c.level == 1 && c.due_day == DAY + 1);
    /* The original model only permits undo for first-known/familiar answers. */
    assert(info(e).can_undo == 0 && !xkl_engine_undo(e, ++clock));
    roundtrip(&e);
    assert(xkl_engine_start(e, DAY + 1, ++clock));
    assert(info(e).word == 0 && info(e).review_remaining == 1);
    exam_grade(e, 0, 0, &clock);
    c = pocket_unpack_card(xkl_engine_card(e, 0));
    assert(c.level == 2 && c.due_day == DAY + 3);
    xkl_engine_free(e);
    puts("PASS short-plan familiar undo; one-question tail removes 2 and retains tomorrow; original undo gate; invalid plans atomic");
}
static void compare_live(const xkl_engine_t *a, const xkl_engine_t *b) {
    pocket_word_state_t sa = checkpoint(a), sb = checkpoint(b);
    assert(!memcmp(&sa, &sb, sizeof(sa)));
    xkl_info_t ia = info(a), ib = info(b);
    assert(!memcmp(&ia, &ib, sizeof(ia)));
    assert(xkl_engine_current_repeats(a) == xkl_engine_current_repeats(b));
    for (uint32_t i = 0; i < XKL_WORD_COUNT; ++i)
        assert(xkl_engine_card(a, i) == xkl_engine_card(b, i));
}
static void test_exam_rotation_parity(void) {
    for (unsigned mode = 0; mode < 3; ++mode) {
        xkl_engine_t *a = blank(mode == 2 ? 1 : 25, stream_a);
        xkl_engine_t *b = blank(mode == 2 ? 1 : 25, stream_a);
        int64_t clock = 10;
        assert(xkl_engine_start(a, DAY, clock));
        assert(xkl_engine_start(b, DAY, clock));
        uint32_t target = info(a).word, first = info(a).log_records + 1;
        bool short_active = true, failed_again = false;
        unsigned turns = 0, tails = 0, shortened = 0;
        while (info(a).has_task) {
            compare_live(a, b);
            assert(xkl_engine_reveal(a, ++clock));
            assert(xkl_engine_reveal(b, clock));
            uint32_t log_total = info(b).log_records;
            assert(xkl_engine_rotate_log(b, first));
            assert(xkl_engine_log_base(b) == log_total);
            assert(info(b).log_records == log_total);
            roundtrip(&b);
            compare_live(a, b);
            int answer = turns == 0 ? 1 : 0;
            uint32_t plan = turns == 0 ? 1 : (info(a).word == target && short_active ? 2 : 0);
            if (mode == 1 && !failed_again && info(a).word == target && info(a).stage == 4) {
                answer = 1;
                plan = 0;
                short_active = false;
                failed_again = true;
            }
            xkl_policy_result_t pa, pb;
            xkl_exam_result_t ea, eb;
            assert(xkl_engine_answer_exam(a, answer, ++clock, true, first, plan, &pa, &ea));
            assert(xkl_engine_answer_exam(b, answer, clock, true, first, plan, &pb, &eb));
            assert(!memcmp(&pa, &pb, sizeof(pa)));
            assert(!memcmp(&ea, &eb, sizeof(ea)));
            xkl_event_info_t log_a, log_b;
            assert(xkl_engine_event(a, pa.answer_sequence - 1u, &log_a));
            assert(xkl_engine_event(b, pb.answer_sequence - 1u, &log_b));
            assert(!memcmp(&log_a, &log_b, sizeof(log_a)));
            compare_live(a, b);
            shortened += ea.shortened_repeats;
            tails += ea.tail_removed;
            assert(++turns < 50);
        }
        assert(shortened == 4);
        if (mode == 1) assert(failed_again);
        if (mode == 2) assert(tails == 2 && turns == 2);
        assert(xkl_engine_rotate_log(b, first));
        roundtrip(&b);
        compare_live(a, b);
        assert(xkl_engine_start(a, DAY + 1, ++clock));
        assert(xkl_engine_start(b, DAY + 1, clock));
        compare_live(a, b);
        assert(info(a).word == target && info(a).review_remaining == 1);
        xkl_engine_free(a);
        xkl_engine_free(b);
    }
    puts("PASS exam short/7-restoration/tail decisions and global events identical across every-turn rotation");
}
static void assert_event_counts(const xkl_engine_t *e, unsigned correct, unsigned wrong) {
    unsigned actual_correct = 0, actual_wrong = 0;
    for (uint32_t i = 0; i < info(e).log_records; ++i) {
        xkl_event_info_t event;
        assert(xkl_engine_event(e, i, &event));
        if (event.kind == 5u) ++actual_correct;
        if (event.kind == 6u) ++actual_wrong;
    }
    assert(actual_correct == correct && actual_wrong == wrong);
}
static void test_exam_initial_correct_training(void) {
    for (uint32_t plan = 3; plan <= 4; ++plan) {
        xkl_engine_t *e = blank(25, stream_a);
        int64_t clock = 10;
        assert(!xkl_engine_current_is_new(e));
        assert(xkl_engine_start(e, DAY, ++clock));
        uint32_t word = info(e).word;
        assert(xkl_engine_current_is_new(e));
        xkl_exam_result_t result = exam_grade(e, 0, plan, &clock);
        unsigned expected = plan == 3 ? 3 : 7;
        assert(result.initial_learning_scheduled == 1);
        assert(result.initial_learning_repeats == expected);
        assert(result.shortened_repeats == 7u - expected);
        assert(!result.tail_removed && !result.tail_deferred);
        assert(info(e).first_known == 0 && info(e).completed == 0);
        assert(info(e).new_remaining == 25 && !info(e).can_undo);
        uint8_t stages[7];
        assert(stages_for(e, word, stages) == expected);
        for (unsigned i = 0; i < expected; ++i)
            assert(stages[i] == (plan == 3 ? 1u + i * 3u : 1u + i));
        roundtrip(&e);
        unsigned recalls = 0;
        while (info(e).has_task) {
            if (info(e).word == word) {
                assert(!xkl_engine_current_is_new(e));
                ++recalls;
                result = exam_grade(e, 0, 0, &clock);
                assert(!result.initial_learning_scheduled && !result.initial_learning_repeats);
            } else {
                assert(xkl_engine_current_is_new(e));
                exam_grade(e, 2, 0, &clock);
            }
        }
        assert(recalls == expected);
        pocket_card_t c = pocket_unpack_card(xkl_engine_card(e, word));
        assert(c.learned && c.level == 1 && c.due_day == DAY + 1 && !c.familiar);
        assert(info(e).first_known == 0 && info(e).familiar == 24);
        assert_event_counts(e, 1u + expected, 0);
        assert(xkl_engine_start(e, DAY + 1, ++clock));
        assert(info(e).word == word && info(e).review_remaining == 1);
        assert(!xkl_engine_current_is_new(e));
        exam_grade(e, 0, 0, &clock);
        c = pocket_unpack_card(xkl_engine_card(e, word));
        assert(c.learned && c.level == 2 && c.due_day == DAY + 3);
        assert(info(e).first_known == 0);
        xkl_engine_free(e);
    }
    puts("PASS correct new questions start exactly 3/7 checks, log CORRECT only, then ordinary cross-day reviews");
}
static void test_exam_all_new_train(void) {
    xkl_engine_t *e = blank(25, stream_a);
    int64_t clock = 10;
    assert(xkl_engine_start(e, DAY, ++clock));
    unsigned starts = 0, turns = 0, seen[25] = {0};
    while (info(e).has_task) {
        uint32_t word = info(e).word;
        assert(word < 25);
        bool virgin = xkl_engine_current_is_new(e);
        xkl_exam_result_t result = exam_grade(e, 0, virgin ? 3 : 2, &clock);
        if (virgin) { ++starts; assert(seen[word] == 0 && result.initial_learning_scheduled); }
        assert(++seen[word] <= 4);
        assert(++turns <= 100);
        assert(info(e).first_known == 0 && info(e).familiar == 0);
    }
    assert(starts == 25 && info(e).completed == 25);
    for (uint32_t word = 0; word < 25; ++word) {
        assert(seen[word] >= 2);
        pocket_card_t c = pocket_unpack_card(xkl_engine_card(e, word));
        assert(c.learned && c.level == 1 && c.due_day == DAY + 1 && !c.familiar);
    }
    assert_event_counts(e, turns, 0);
    check_tail(e, 25);
    roundtrip(&e);
    assert(xkl_engine_start(e, DAY + 1, ++clock));
    assert(info(e).review_remaining == 25 && info(e).new_remaining == 0);
    xkl_engine_free(e);
    puts("PASS all 25 new questions train after correct choices; no automatic permanent known classification");
}
static void test_exam_initial_correct_then_errors(void) {
    xkl_engine_t *e = blank(4, stream_a);
    int64_t clock = 10;
    assert(xkl_engine_start(e, DAY, ++clock));
    uint32_t word = info(e).word;
    exam_grade(e, 0, 3, &clock);
    while (info(e).word != word) exam_grade(e, 2, 0, &clock);
    xkl_exam_result_t result = exam_grade(e, 1, 1, &clock);
    assert(result.shortened_repeats == 4 && !result.initial_learning_scheduled);
    assert(stages_for(e, word, NULL) == 3);
    while (info(e).word != word) exam_grade(e, 2, 0, &clock);
    result = exam_grade(e, 1, 0, &clock);
    assert(stages_for(e, word, NULL) == 7 && !result.initial_learning_scheduled);
    unsigned correct = 1;
    while (info(e).has_task) {
        if (info(e).word == word) { exam_grade(e, 0, 0, &clock); ++correct; }
        else exam_grade(e, 2, 0, &clock);
    }
    assert_event_counts(e, correct, 2);
    assert(info(e).first_known == 0);
    xkl_engine_free(e);
    puts("PASS initially correct training does not count as error; first real wrong short, next real wrong restores 7");
}
static void test_exam_initial_correct_tail_and_familiar(void) {
    xkl_engine_t *e = blank(1, stream_a);
    int64_t clock = 10;
    assert(xkl_engine_start(e, DAY, ++clock));
    assert(xkl_engine_current_is_new(e));
    exam_grade(e, 2, 0, &clock);
    assert(info(e).familiar == 1 && !info(e).has_task);
    assert(xkl_engine_undo(e, ++clock));
    assert(xkl_engine_current_is_new(e) && info(e).familiar == 0);
    exam_grade(e, 0, 3, &clock);
    assert(!xkl_engine_current_is_new(e) && xkl_engine_current_repeats(e) == 3);
    uint32_t packed = xkl_engine_card(e, 0);
    exam_grade(e, 2, 0, &clock);
    assert(info(e).familiar == 1 && info(e).can_undo);
    assert(xkl_engine_undo(e, ++clock));
    assert(info(e).familiar == 0 && xkl_engine_current_repeats(e) == 3);
    assert(xkl_engine_card(e, 0) == packed);
    roundtrip(&e);
    xkl_exam_result_t result = exam_grade(e, 0, 2, &clock);
    assert(result.tail_removed == 2 && result.tail_deferred == 1);
    assert(!info(e).has_task && info(e).first_known == 0 && info(e).familiar == 0);
    pocket_card_t c = pocket_unpack_card(xkl_engine_card(e, 0));
    assert(c.learned && c.level == 1 && c.due_day == DAY + 1);
    assert_event_counts(e, 2, 0);
    assert(xkl_engine_start(e, DAY + 1, ++clock));
    exam_grade(e, 2, 0, &clock);
    assert(info(e).familiar == 1 && !info(e).has_task);
    assert(xkl_engine_undo(e, ++clock));
    assert(info(e).review_remaining == 1 && info(e).familiar == 0);
    xkl_engine_free(e);
    puts("PASS initial correct tail keeps tomorrow; explicit familiar and undo work before, during and after training");
}
static void test_exam_initial_correct_invalid_atomic(void) {
    xkl_engine_t *e = blank(1, stream_a);
    int64_t clock = 10;
    assert(!xkl_engine_current_is_new(NULL));
    assert(xkl_engine_start(e, DAY, ++clock));
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 3, NULL, NULL));
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 4, NULL, NULL));
    assert(xkl_engine_reveal(e, ++clock));
    size_t before_size, after_size;
    uint8_t *before = snapshot(e, &before_size);
    for (uint32_t plan = 3; plan <= 4; ++plan)
        for (int answer = 1; answer <= 3; ++answer)
            assert(!xkl_engine_answer_exam(e, answer, ++clock, false, 1, plan, NULL, NULL));
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 5, NULL, NULL));
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, UINT32_MAX, NULL, NULL));
    uint8_t *after = snapshot(e, &after_size);
    assert(before_size == after_size && !memcmp(before, after, before_size));
    free(before); free(after);
    exam_grade(e, 0, 3, &clock);
    assert(xkl_engine_reveal(e, ++clock));
    before = snapshot(e, &before_size);
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 3, NULL, NULL));
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 4, NULL, NULL));
    after = snapshot(e, &after_size);
    assert(before_size == after_size && !memcmp(before, after, before_size));
    free(before); free(after);
    exam_grade(e, 0, 2, &clock);
    assert(xkl_engine_start(e, DAY + 1, ++clock));
    assert(xkl_engine_reveal(e, ++clock));
    before = snapshot(e, &before_size);
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 3, NULL, NULL));
    assert(!xkl_engine_answer_exam(e, 0, ++clock, false, 1, 4, NULL, NULL));
    after = snapshot(e, &after_size);
    assert(before_size == after_size && !memcmp(before, after, before_size));
    free(before); free(after);
    xkl_engine_free(e);
    puts("PASS initial learning plans require revealed correct virgin question; invalid attempts change no snapshot bytes");
}
static void test_exam_initial_learning_rotation(void) {
    for (uint32_t plan = 3; plan <= 4; ++plan) {
        xkl_engine_t *a = blank(5, stream_a), *b = blank(5, stream_a);
        int64_t clock = 10;
        assert(xkl_engine_start(a, DAY, clock));
        assert(xkl_engine_start(b, DAY, clock));
        uint32_t first = info(a).log_records + 1;
        unsigned turns = 0;
        while (info(a).has_task) {
            compare_live(a, b);
            bool virgin = xkl_engine_current_is_new(a);
            assert(virgin == xkl_engine_current_is_new(b));
            uint32_t selected_plan = virgin ? plan : (plan == 3 ? 2 : 0);
            assert(xkl_engine_reveal(a, ++clock));
            assert(xkl_engine_reveal(b, clock));
            assert(xkl_engine_rotate_log(b, first));
            roundtrip(&b);
            xkl_policy_result_t pa, pb;
            xkl_exam_result_t ea, eb;
            assert(xkl_engine_answer_exam(a, 0, ++clock, true, first, selected_plan, &pa, &ea));
            assert(xkl_engine_answer_exam(b, 0, clock, true, first, selected_plan, &pb, &eb));
            assert(!memcmp(&pa, &pb, sizeof(pa)) && !memcmp(&ea, &eb, sizeof(ea)));
            xkl_event_info_t la, lb;
            assert(xkl_engine_event(a, pa.answer_sequence - 1u, &la));
            assert(xkl_engine_event(b, pb.answer_sequence - 1u, &lb));
            assert(la.kind == 5u && !memcmp(&la, &lb, sizeof(la)));
            compare_live(a, b);
            assert(++turns <= 40);
        }
        assert(info(a).first_known == 0);
        assert(xkl_engine_start(a, DAY + 1, ++clock));
        assert(xkl_engine_start(b, DAY + 1, clock));
        compare_live(a, b);
        assert(info(a).review_remaining == 5);
        xkl_engine_free(a); xkl_engine_free(b);
    }
    puts("PASS initial correct 3/7 learning decisions, truthful events and due cards survive every-turn log rotation");
}
int main(void) {
    setbuf(stdout, NULL);
    test_blank_validation();
    test_all_first_known();
    test_isolation_restore();
    test_original_reinforcement_and_days();
    test_uncapped_review();
    test_exam_short_rewrong();
    test_exam_disabled_parity();
    test_exam_short_tail_and_invalid_plans();
    test_exam_rotation_parity();
    test_exam_initial_correct_training();
    test_exam_all_new_train();
    test_exam_initial_correct_then_errors();
    test_exam_initial_correct_tail_and_familiar();
    test_exam_initial_correct_invalid_atomic();
    test_exam_initial_learning_rotation();
    return 0;
}
