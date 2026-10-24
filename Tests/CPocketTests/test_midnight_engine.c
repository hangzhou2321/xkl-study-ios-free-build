#include "xkl_engine.h"
#include "pocket_word_model.h"
#include "pocket_log.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* All cards are synthetic fixtures. No personal file is opened or rewritten. */
#define DAY 20746u
#define CP_OFFSET 96u
#define CARD_OFFSET (96u + 2316u)
static const uint8_t stream[16] = {0x81, 0x42, 0x13, 0x24, 0x15};
static uint32_t get32(const uint8_t *p) {
    return p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static void put32(uint8_t *p, uint32_t n) {
    for (unsigned i=0;i<4;++i) p[i]=(uint8_t)(n>>(8*i));
}
static uint32_t crc32(const uint8_t *p,size_t n) {
    uint32_t c=UINT32_MAX;
    while(n--) { c^=*p++; for(unsigned j=0;j<8;++j)c=(c>>1)^(UINT32_C(0xedb88320)&(0u-(c&1u))); }
    return ~c;
}
static bool read_fixture(uint16_t id,uint32_t *out,void *ctx) {
    if(id>=XKL_WORD_COUNT)return false;
    *out=get32((uint8_t *)ctx+CARD_OFFSET+4u*id);return true;
}
static uint8_t *snapshot(xkl_engine_t *e,size_t *size) {
    *size=xkl_engine_snapshot_size(e);assert(*size);
    uint8_t *bytes=malloc(*size);assert(bytes);
    assert(xkl_engine_snapshot(e,bytes,*size)==*size);return bytes;
}
static pocket_word_state_t checkpoint(xkl_engine_t *e) {
    size_t n;uint8_t *p=snapshot(e,&n);pocket_word_state_t s;
    assert(sizeof(s)==2316u);memcpy(&s,p+CP_OFFSET,sizeof(s));free(p);
    assert(pocket_word_valid(&s));return s;
}
static xkl_info_t info(xkl_engine_t *e) {
    xkl_info_t out;assert(xkl_engine_info(e,&out));return out;
}
static uint8_t *log_copy(xkl_engine_t *e,size_t *n) {
    *n=xkl_engine_log_size(e);assert(*n);
    uint8_t *p=malloc(*n);assert(p);assert(xkl_engine_log(e,p,*n)==*n);return p;
}
static void log_prefix(xkl_engine_t *e,const uint8_t *prefix,size_t n) {
    size_t total;uint8_t *log=log_copy(e,&total);assert(total>=n);assert(!memcmp(log,prefix,n));free(log);
}
static void cards_same(xkl_engine_t *e,const uint8_t *old) {
    for(unsigned i=0;i<XKL_WORD_COUNT;++i)assert(xkl_engine_card(e,i)==get32(old+CARD_OFFSET+4u*i));
}
static void old_tokens_preserved(const pocket_word_state_t *before,const pocket_word_state_t *after) {
    assert(before->body.length);
    assert(!memcmp(&before->body.queue[0],&after->body.queue[0],sizeof(pocket_token_t)));
    unsigned old=0;
    for(unsigned i=0;i<after->body.length&&old<before->body.length;++i)
        if(after->body.queue[i].slot==before->body.queue[old].slot &&
           after->body.queue[i].stage==before->body.queue[old].stage)++old;
    assert(old==before->body.length);
    for(unsigned i=0;i<POCKET_ACTIVE_MAX;++i)
        if(before->body.active[i].used)
            assert(!memcmp(&before->body.active[i],&after->body.active[i],sizeof(pocket_cached_t)));
    assert(before->body.new_total==after->body.new_total);
    assert(before->body.new_loaded==after->body.new_loaded);
    assert(before->body.new_done==after->body.new_done);
    assert(before->body.new_cursor==after->body.new_cursor);
    assert(before->body.new_end==after->body.new_end);
    assert(before->body.lesson==after->body.lesson);
}
static unsigned tokens_for(const pocket_word_state_t *s,uint32_t word) {
    unsigned count=0;
    for(unsigned i=0;i<s->body.length;++i)
        if(s->body.active[s->body.queue[i].slot].word==word)++count;
    return count;
}
static unsigned active_count(const pocket_word_state_t *s) {
    unsigned n=0;for(unsigned i=0;i<POCKET_ACTIVE_MAX;++i)n+=s->body.active[i].used;return n;
}
static void grade(xkl_engine_t *e,int choice,int64_t *clock) {
    assert(xkl_engine_reveal(e,++*clock));assert(xkl_engine_answer(e,choice,++*clock));
}
static uint32_t learned(uint32_t due,unsigned level) {
    pocket_card_t c={.due_day=due,.level=(uint8_t)level,.learned=1};return pocket_pack_card(c);
}
/* Seed a valid pre-event snapshot so tests do not manufacture answered events.
   Active/unseen sets are deliberately independent of the user's collections. */
static xkl_engine_t *fixture(unsigned old_first,unsigned old_count,unsigned next_first,
                            unsigned next_count,unsigned new_first,unsigned new_count,
                            bool legacy_day,bool huge_done) {
    xkl_engine_t *blank=xkl_engine_blank(XKL_WORD_COUNT,stream);assert(blank);
    size_t n;uint8_t *p=snapshot(blank,&n);xkl_engine_free(blank);
    pocket_card_t known={.due_day=UINT32_MAX,.learned=1};
    uint32_t inactive=pocket_pack_card(known)|POCKET_IMPORTED_KNOWN;
    for(unsigned i=0;i<XKL_WORD_COUNT;++i)put32(p+CARD_OFFSET+4u*i,
        huge_done?learned(DAY+2,2):inactive);
    for(unsigned i=old_first;i<old_first+old_count;++i)put32(p+CARD_OFFSET+4u*i,learned(DAY,1));
    for(unsigned i=next_first;i<next_first+next_count;++i)put32(p+CARD_OFFSET+4u*i,learned(DAY+1,1));
    for(unsigned i=new_first;i<new_first+new_count;++i)put32(p+CARD_OFFSET+4u*i,0);
    if(legacy_day||huge_done) {
        pocket_word_state_t s;pocket_word_init(&s);assert(pocket_word_start(&s,DAY,read_fixture,p));
        if(legacy_day)s.body.day=DAY+1; /* Exactly the old length>0 start behavior. */
        if(huge_done) {
            s.body.review_done=(uint16_t)(XKL_WORD_COUNT-50u);
            s.body.review_loaded=s.body.review_total=XKL_WORD_COUNT;
            s.body.completed=s.body.review_done;
        }
        pocket_word_seal(&s);assert(pocket_word_valid(&s));memcpy(p+CP_OFFSET,&s,sizeof(s));
    }
    put32(p+n-4,crc32(p,n-4));
    xkl_engine_t *e=xkl_engine_restore(p,n);assert(e);free(p);return e;
}

static void test_47_due_and_preserved_reinforcement(void) {
    xkl_engine_t *e=fixture(0,0,0,47,50,50,false,false);int64_t clock=100;
    assert(xkl_engine_start(e,DAY,clock));
    assert(info(e).new_remaining==25&&info(e).review_remaining==0);
    uint32_t failed=info(e).word;grade(e,1,&clock);
    uint32_t partial=info(e).word;grade(e,3,&clock);
    pocket_word_state_t before=checkpoint(e);
    assert(tokens_for(&before,failed)==7&&tokens_for(&before,partial)==1);
    assert(active_count(&before)==25);
    size_t snapshot_n,log_n;uint8_t *old=snapshot(e,&snapshot_n),*log=log_copy(e,&log_n);
    uint32_t head=info(e).word;
    assert(xkl_engine_start(e,DAY+1,++clock));
    pocket_word_state_t after=checkpoint(e);old_tokens_preserved(&before,&after);
    assert(info(e).word==head&&info(e).selection_day==DAY+1);
    assert(info(e).new_remaining==25&&info(e).review_remaining==47);
    assert(after.body.review_loaded==25&&active_count(&after)==50);
    for(unsigned i=0;i<25;++i)
        assert(after.body.active[after.body.queue[1+i].slot].word==i);
    cards_same(e,old);log_prefix(e,log,log_n);
    assert(tokens_for(&after,failed)==7&&tokens_for(&after,partial)==1);
    assert(xkl_engine_start(e,DAY+1,++clock));pocket_word_state_t again=checkpoint(e);
    assert(!memcmp(&after.body,&again.body,sizeof(after.body)));
    cards_same(e,old);log_prefix(e,log,log_n);
    size_t n;uint8_t *saved=snapshot(e,&n);xkl_engine_t *restored=xkl_engine_restore(saved,n);assert(restored);
    assert(xkl_engine_start(restored,DAY+1,1));pocket_word_state_t resumed=checkpoint(restored);
    assert(!memcmp(&again.body,&resumed.body,sizeof(again.body)));
    free(saved);free(log);free(old);xkl_engine_free(restored);xkl_engine_free(e);
    puts("PASS 47 due admitted, current head and seven/partial tokens kept, review priority, repeat/restore idempotent");
}

static void test_same_day_legacy_cutoff(void) {
    xkl_engine_t *e=fixture(0,0,0,47,50,25,true,false);
    assert(info(e).day==DAY+1&&info(e).selection_day==DAY&&info(e).review_remaining==0);
    pocket_word_state_t before=checkpoint(e);
    assert(xkl_engine_start(e,DAY+1,1));pocket_word_state_t after=checkpoint(e);
    old_tokens_preserved(&before,&after);
    assert(info(e).review_remaining==47&&info(e).selection_day==DAY+1);
    assert(xkl_engine_start(e,DAY+1,2));pocket_word_state_t repeated=checkpoint(e);
    assert(!memcmp(&after.body,&repeated.body,sizeof(after.body)));
    xkl_engine_free(e);puts("PASS same-day repair when legacy day already advanced but selection_day was stale");
}

static void test_full_cache_low_id_backfill(void) {
    xkl_engine_t *e=fixture(100,55,0,4,0,0,false,false);int64_t clock=100;
    assert(xkl_engine_start(e,DAY,clock));
    grade(e,0,&clock); /* done=1, active still full due to old pending reviews */
    pocket_word_state_t before=checkpoint(e);assert(active_count(&before)==50&&before.body.review_cursor==151);
    assert(xkl_engine_start(e,DAY+1,++clock));pocket_word_state_t after=checkpoint(e);
    old_tokens_preserved(&before,&after);
    assert(after.body.review_total==59&&after.body.review_done==1&&after.body.review_cursor==0);
    assert(after.body.length==before.body.length); /* No eviction to admit new due. */
    grade(e,0,&clock);after=checkpoint(e);
    assert(tokens_for(&after,0)==1&&active_count(&after)==50);
    assert(after.body.review_done==2&&after.body.review_loaded==52);
    xkl_engine_free(e);puts("PASS full 50-slot cache preserves all words and refills newly due IDs behind yesterday's cursor");
}

static void test_finishing_card_overlay_prevents_duplicate(void) {
    xkl_engine_t *e=fixture(0,50,100,4,0,0,false,false);int64_t clock=100;
    assert(xkl_engine_start(e,DAY,clock));
    assert(xkl_engine_start(e,DAY+1,++clock));
    assert(info(e).word==0);grade(e,0,&clock);
    pocket_word_state_t s=checkpoint(e);
    assert(tokens_for(&s,0)==0&&tokens_for(&s,100)==1);
    assert(pocket_unpack_card(xkl_engine_card(e,0)).due_day==DAY+3);
    assert(s.body.review_done==1&&s.body.review_loaded==51&&s.body.review_total==54);
    /* Drain all selected due cards. No just-finished stale backing value may
       be re-admitted by the reset scanner. Every word receives one grade. */
    bool seen[XKL_WORD_COUNT]={false};seen[0]=true;unsigned count=1;
    while(info(e).has_task) {
        uint32_t w=info(e).word;assert(w<XKL_WORD_COUNT&&!seen[w]);seen[w]=true;
        assert(count++<54);grade(e,0,&clock);
    }
    assert(count==54);xkl_engine_free(e);
    puts("PASS candidate changed-card overlay prevents duplicate review during pre-commit refill");
}

static void test_cross_day_undo_keeps_new_reviews(void) {
    xkl_engine_t *e=fixture(0,0,100,4,0,25,false,false);int64_t clock=100;
    assert(xkl_engine_start(e,DAY,clock));uint32_t word=info(e).word;
    assert(xkl_engine_answer(e,2,++clock));assert(info(e).can_undo&&info(e).familiar==1);
    assert(xkl_engine_start(e,DAY+1,++clock));assert(info(e).review_remaining==4);
    size_t log_n;uint8_t *log=log_copy(e,&log_n);
    assert(xkl_engine_undo(e,++clock));pocket_word_state_t s=checkpoint(e);
    assert(info(e).word==word&&info(e).selection_day==DAY+1&&info(e).day==DAY+1);
    assert(info(e).review_remaining==4&&info(e).new_remaining==25);
    assert(xkl_engine_card(e,word)==0&&info(e).familiar==0);
    for(unsigned i=100;i<104;++i)assert(tokens_for(&s,i)==1);
    assert(tokens_for(&s,word)==1);log_prefix(e,log,log_n);
    size_t n;uint8_t *saved=snapshot(e,&n);xkl_engine_t *r=xkl_engine_restore(saved,n);assert(r);
    assert(info(r).review_remaining==4&&info(r).word==word);
    free(saved);free(log);xkl_engine_free(r);xkl_engine_free(e);
    puts("PASS cross-day familiar undo restores target and refreshes old undo cutoff without discarding today's due");
}

static void test_completed_word_can_be_due_again_next_selection(void) {
    xkl_engine_t *e=fixture(0,55,0,0,0,0,false,false);int64_t clock=100;
    assert(xkl_engine_start(e,DAY,clock));grade(e,0,&clock);
    assert(pocket_unpack_card(xkl_engine_card(e,0)).due_day==DAY+2);
    assert(xkl_engine_start(e,DAY+2,++clock));pocket_word_state_t s=checkpoint(e);
    assert(s.body.review_done==1&&s.body.review_total==56&&s.body.review_cursor==0);
    grade(e,0,&clock);s=checkpoint(e);
    assert(tokens_for(&s,0)==1); /* A legitimate later-day review, not same-day repetition. */
    xkl_engine_free(e);puts("PASS previously completed word becomes eligible again on its real due day without erasing historical completion");
}

static void test_limits_and_backwards_date_are_atomic_failures(void) {
    xkl_engine_t *e=fixture(0,50,0,0,0,0,false,true);
    pocket_word_state_t state=checkpoint(e);assert(state.body.review_total==XKL_WORD_COUNT);
    size_t n;uint8_t *before=snapshot(e,&n);
    assert(!xkl_engine_start(e,DAY+2,100));size_t m;uint8_t *after=snapshot(e,&m);
    assert(m==n&&!memcmp(before,after,n));free(after);
    assert(!xkl_engine_start(e,DAY-1,101));after=snapshot(e,&m);
    assert(m==n&&!memcmp(before,after,n));free(after);free(before);xkl_engine_free(e);
    puts("PASS counter overflow and backwards date fail before log/checkpoint/card mutation");
}

int main(void) {
    test_47_due_and_preserved_reinforcement();
    test_same_day_legacy_cutoff();
    test_full_cache_low_id_backfill();
    test_finishing_card_overlay_prevents_duplicate();
    test_cross_day_undo_keeps_new_reviews();
    test_completed_word_can_be_due_again_next_selection();
    test_limits_and_backwards_date_are_atomic_failures();
    puts("PASS midnight C admission: 7 synthetic test groups");
    return 0;
}
