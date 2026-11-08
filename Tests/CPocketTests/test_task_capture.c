#include "xkl_engine.h"
#include "pocket_word_model.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Entirely synthetic IDs and card data. */
#define DAY 20745u
#define BANK 310u
static const uint8_t stream[16] = {0x31, 0x42, 0x53, 0x64};

static uint8_t *snapshot(xkl_engine_t *e, size_t *size) {
    *size = xkl_engine_snapshot_size(e);
    assert(*size);
    uint8_t *p = malloc(*size); assert(p);
    assert(xkl_engine_snapshot(e, p, *size) == *size);
    return p;
}

static void test_large_queue_and_calendar(void) {
    uint32_t cards[BANK];
    const uint32_t complete = pocket_pack_card((pocket_card_t){.due_day=UINT32_MAX, .learned=1}) | POCKET_IMPORTED_KNOWN;
    for (uint32_t i=0; i<BANK; ++i) cards[i]=complete;
    for (uint32_t i=0; i<267; ++i)
        cards[i]=pocket_pack_card((pocket_card_t){.due_day=DAY-1u, .level=1, .learned=1});
    for (uint32_t i=267; i<275; ++i)
        cards[i]=pocket_pack_card((pocket_card_t){.due_day=DAY+1u, .level=1, .learned=1});
    for (uint32_t i=275; i<300; ++i) cards[i]=0;
    xkl_engine_t *e=xkl_engine_import_cards(BANK,cards,DAY,XKL_NO_WORD,stream); assert(e);
    assert(xkl_engine_start(e,DAY,1));
    assert(xkl_engine_reveal(e,2));
    assert(xkl_engine_answer_exam(e,1,3,false,1,1,NULL,NULL));
    xkl_info_t original; assert(xkl_engine_info(e,&original));
    assert(original.total_remaining==292u);
    size_t n; uint8_t *before=snapshot(e,&n);
    xkl_task_capture_info_t info={0};
    assert(xkl_engine_capture_task(e,BANK,DAY,NULL,0,NULL,0,&info));
    assert(info.day==DAY && info.selection_day==DAY);
    assert(info.item_count==292 && info.token_count==52 && info.active_count==50);
    assert(info.unloaded_review_count==217 && info.unloaded_new_count==25);
    assert(!info.can_undo && info.undo_word==XKL_NO_WORD);
    xkl_task_token_t tokens[350]; xkl_task_item_t items[BANK];
    memset(tokens,0xa5,sizeof(tokens)); memset(items,0xa5,sizeof(items));
    assert(xkl_engine_capture_task(e,BANK,DAY+1,tokens,350,items,BANK,&info));
    assert(info.item_count==292 && info.selection_day==DAY);
    pocket_word_state_t checkpoint;
    memcpy(&checkpoint,before+96,sizeof(checkpoint)); assert(pocket_word_valid(&checkpoint));
    for (uint32_t i=0;i<info.token_count;++i) {
        pocket_token_t t=checkpoint.body.queue[i];
        pocket_word_cached_t a=checkpoint.body.active[t.slot];
        assert(tokens[i].word==a.word && tokens[i].stage==t.stage && tokens[i].failed_round==a.failed_round);
    }
    bool seen[BANK]={false}; uint32_t failcount=0;
    for (uint32_t i=0; i<info.item_count; ++i) {
        xkl_task_item_t a=items[i]; assert(a.word<BANK && !seen[a.word]); seen[a.word]=true;
        if (i<50) {
            uint32_t failed=99; assert(a.category==XKL_TASK_ACTIVE_REVIEW);
            assert(a.stage_mask==xkl_engine_pending_stages(e,a.word,&failed));
            assert(a.failed_round==failed);
            if (failed==1) { ++failcount; assert(a.word==0 && a.stage_mask==146); }
        } else if (i<267) { assert(a.category==XKL_TASK_UNLOADED_REVIEW && !a.stage_mask && !a.failed_round); }
        else { assert(a.category==XKL_TASK_UNLOADED_NEW && !a.stage_mask && !a.failed_round); }
    }
    assert(failcount==1);
    for (uint32_t i=0;i<267;++i) assert(seen[i]);
    for (uint32_t i=267;i<275;++i) assert(!seen[i]); /* tomorrow's due is not old task */
    for (uint32_t i=275;i<300;++i) assert(seen[i]);
    assert(tokens[0].word==1 && tokens[0].stage==0);
    assert(tokens[0].word==original.word && tokens[0].stage==original.stage);
    size_t after_n; uint8_t *after=snapshot(e,&after_n);
    assert(n==after_n && !memcmp(before,after,n)); free(after);

    /* Capacity, bank and clock failures leave every output byte untouched. */
    xkl_task_capture_info_t untouched; memset(&untouched,0x5a,sizeof(untouched));
    xkl_task_capture_info_t sentinel=untouched;
    xkl_task_token_t token_sentinel=tokens[0]; xkl_task_item_t item_sentinel=items[0];
    assert(!xkl_engine_capture_task(e,BANK,DAY,tokens,51,items,BANK,&untouched));
    assert(!memcmp(&sentinel,&untouched,sizeof(sentinel)));
    assert(!memcmp(&token_sentinel,&tokens[0],sizeof(token_sentinel)));
    assert(!memcmp(&item_sentinel,&items[0],sizeof(item_sentinel)));
    assert(!xkl_engine_capture_task(e,BANK,DAY-1,tokens,350,items,BANK,&untouched));
    assert(!xkl_engine_capture_task(e,100,DAY,tokens,350,items,BANK,&untouched));
    after=snapshot(e,&after_n); assert(n==after_n && !memcmp(before,after,n)); free(after);
    before[n-1]^=1; assert(!xkl_engine_restore(before,n));
    free(before); xkl_engine_free(e);
    puts("PASS capture 292 selected, exact stages, midnight separation, atomic failures and unchanged snapshot");
}

static void test_undo_and_empty_task(void) {
    xkl_engine_t *e=xkl_engine_blank(1,stream); assert(e);
    xkl_task_capture_info_t info;
    assert(xkl_engine_capture_task(e,1,DAY,NULL,0,NULL,0,&info));
    assert(info.item_count==0 && info.token_count==0 && !info.can_undo);
    assert(xkl_engine_start(e,DAY,1));
    assert(xkl_engine_reveal(e,2)); assert(xkl_engine_answer(e,0,3));
    assert(xkl_engine_capture_task(e,1,DAY,NULL,0,NULL,0,&info));
    assert(info.item_count==0 && info.can_undo && info.undo_word==0);
    assert(xkl_engine_undo(e,4));
    assert(xkl_engine_capture_task(e,1,DAY,NULL,0,NULL,0,&info));
    assert(info.item_count==1 && !info.can_undo);
    xkl_engine_free(e);
    puts("PASS empty task and genuine undo remain usable");
}

static void test_mixed_queue_after_midnight(void) {
    uint32_t cards[BANK];
    const uint32_t complete = pocket_pack_card((pocket_card_t){.due_day=UINT32_MAX, .learned=1}) | POCKET_IMPORTED_KNOWN;
    for (uint32_t i=0;i<BANK;++i) cards[i]=complete;
    for (uint32_t i=0;i<25;++i)
        cards[i]=pocket_pack_card((pocket_card_t){.due_day=DAY, .level=1, .learned=1});
    for (uint32_t i=25;i<50;++i) cards[i]=0;
    for (uint32_t i=50;i<292;++i)
        cards[i]=pocket_pack_card((pocket_card_t){.due_day=DAY+1u, .level=1, .learned=1});
    xkl_engine_t *e=xkl_engine_import_cards(BANK,cards,DAY,XKL_NO_WORD,stream); assert(e);
    assert(xkl_engine_start(e,DAY,1));
    assert(xkl_engine_start(e,DAY+1u,2));
    size_t n; uint8_t *before=snapshot(e,&n);
    xkl_task_token_t tokens[350]; xkl_task_item_t items[BANK]; xkl_task_capture_info_t info;
    assert(xkl_engine_capture_task(e,BANK,DAY+1u,tokens,350,items,BANK,&info));
    assert(info.token_count==50 && info.item_count==292 && info.active_count==50);
    assert(info.unloaded_review_count==242 && info.unloaded_new_count==0);
    for (uint32_t i=0;i<25;++i)
        assert(items[i].word==i && items[i].category==XKL_TASK_ACTIVE_REVIEW);
    for (uint32_t i=25;i<50;++i)
        assert(items[i].word==i && items[i].category==XKL_TASK_ACTIVE_NEW);
    for (uint32_t i=50;i<292;++i)
        assert(items[i].word==i && items[i].category==XKL_TASK_UNLOADED_REVIEW);
    size_t after_n; uint8_t *after=snapshot(e,&after_n);
    assert(n==after_n && !memcmp(before,after,n));
    free(after); free(before); xkl_engine_free(e);
    puts("PASS midnight-refreshed mixed 25 new + 25 reviews + 242 unloaded reviews");
}

int main(void) { test_large_queue_and_calendar(); test_mixed_queue_after_midnight(); test_undo_and_empty_task(); return 0; }
