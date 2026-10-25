#include "xkl_engine.h"
#include "pocket_word_recording.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IMAGE_BYTES 0x200000u
#define SNAP_HEADER 96u
#define CARD_OFFSET (SNAP_HEADER + 2316u)
static const uint8_t stream[16] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
static bool read_memory(void *ctx, uint32_t at, void *out, size_t n) {
    if (at > IMAGE_BYTES || n > IMAGE_BYTES - at) return false;
    memcpy(out, (uint8_t *)ctx + at, n); return true;
}
static bool write_memory(void *ctx, uint32_t at, const void *p, size_t n) {
    if (at > IMAGE_BYTES || n > IMAGE_BYTES - at) return false;
    memcpy((uint8_t *)ctx + at, p, n); return true;
}
static bool erase_memory(void *ctx, uint32_t at, size_t n) {
    if (at > IMAGE_BYTES || n > IMAGE_BYTES - at) return false;
    memset((uint8_t *)ctx + at, 255, n); return true;
}
static uint32_t get32(const uint8_t *p) { return p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static void put32(uint8_t *p, uint32_t n) { for (unsigned i=0;i<4;++i) p[i]=(uint8_t)(n>>(i*8)); }
static uint32_t crc32(const uint8_t *p,size_t n) {
    uint32_t c=UINT32_MAX; while(n--){c^=*p++;for(unsigned i=0;i<8;++i)c=(c>>1)^(UINT32_C(0xedb88320)&(0u-(c&1u)));}return ~c;
}
static uint8_t *snapshot(xkl_engine_t *e, size_t *n) {
    *n=xkl_engine_snapshot_size(e); assert(*n); uint8_t *p=malloc(*n); assert(p);
    assert(xkl_engine_snapshot(e,p,*n)==*n); return p;
}
static pocket_state_t checkpoint(xkl_engine_t *e) {
    size_t n; uint8_t *p=snapshot(e,&n); pocket_state_t state;
    memcpy(&state,p+SNAP_HEADER,sizeof(state));free(p);assert(pocket_word_valid(&state));return state;
}
static xkl_info_t info(xkl_engine_t *e) { xkl_info_t i; assert(xkl_engine_info(e,&i));return i; }
static uint8_t *fresh_image(void) {
    uint8_t *image=malloc(IMAGE_BYTES);assert(image);memset(image,255,IMAGE_BYTES);
    pocket_storage_t storage; pocket_word_state_t state;pocket_word_init(&state);
    pocket_storage_io_t io={image,IMAGE_BYTES,read_memory,write_memory,erase_memory};
    assert(pocket_storage_open(&storage,io,POCKET_WORD_DECK_ID,XKL_WORD_COUNT,sizeof(state),&state)==POCKET_STORAGE_EMPTY);
    assert(pocket_storage_create(&storage,&state));return image;
}
static xkl_engine_t *fresh(void) { uint8_t *p=fresh_image();xkl_engine_t *e=xkl_engine_seed(p,IMAGE_BYTES,stream);free(p);assert(e);return e; }
static void grade(xkl_engine_t *e,int answer,int64_t *clock) {
    assert(xkl_engine_reveal(e,++*clock));assert(xkl_engine_answer(e,answer,++*clock));
}
static void test_personal(const char *path) {
    FILE *f=fopen(path,"rb");assert(f);uint8_t *image=malloc(IMAGE_BYTES),*copy=malloc(IMAGE_BYTES);assert(image&&copy);
    assert(fread(image,1,IMAGE_BYTES,f)==IMAGE_BYTES);assert(fgetc(f)==EOF);fclose(f);memcpy(copy,image,IMAGE_BYTES);
    pocket_storage_t storage; pocket_state_t state;
    pocket_storage_io_t io={image,IMAGE_BYTES,read_memory,write_memory,erase_memory};
    assert(pocket_storage_open(&storage,io,POCKET_WORD_DECK_ID,XKL_WORD_COUNT,sizeof(state),&state)==POCKET_STORAGE_READY);
    xkl_engine_t *e=xkl_engine_seed(image,IMAGE_BYTES,stream);assert(e);unsigned nonzero=0;
    for(uint32_t i=0;i<XKL_WORD_COUNT;++i){uint32_t p;assert(pocket_storage_card(&storage,i,&p));assert(p==xkl_engine_card(e,i));nonzero+=p!=0;}
    assert(nonzero==8550);pocket_state_t actual=checkpoint(e);assert(memcmp(&state,&actual,sizeof(state))==0);
    assert(memcmp(image,copy,IMAGE_BYTES)==0);assert(xkl_engine_card(e,XKL_WORD_COUNT)==UINT32_MAX);
    size_t n;uint8_t *p=snapshot(e,&n);assert(n<120000);xkl_engine_t *b=xkl_engine_restore(p,n);assert(b);
    for(uint32_t i=0;i<XKL_WORD_COUNT;++i)assert(xkl_engine_card(e,i)==xkl_engine_card(b,i));
    assert(xkl_engine_start(b,20745,100));assert(info(b).review_remaining>25);assert(info(b).new_remaining<=25);
    assert(!xkl_engine_seed(image,IMAGE_BYTES-1,stream));uint8_t zero[16]={0};assert(!xkl_engine_seed(image,IMAGE_BYTES,zero));
    image[4096]^=1;assert(!xkl_engine_seed(image,IMAGE_BYTES,stream));
    free(p);xkl_engine_free(b);xkl_engine_free(e);free(copy);free(image);
    puts("PASS personal seed: 25,644 cards equal; 8,550 nonzero; input unchanged; uncapped reviews");
}
static void test_reveal_undo(void) {
    xkl_engine_t *e=fresh();int64_t clock=100;assert(!xkl_engine_answer(e,0,clock));assert(!xkl_engine_reveal(e,clock));
    assert(xkl_engine_start(e,20745,clock));assert(info(e).new_remaining==25);assert(info(e).review_remaining==0);
    for(int a=0;a<=3;++a)if(a!=2)assert(!xkl_engine_answer(e,a,++clock));
    uint32_t word=info(e).word;assert(xkl_engine_answer(e,2,++clock));assert(info(e).can_undo);
    assert(xkl_engine_card(e,word)&(1u<<21));assert(xkl_engine_undo(e,++clock));assert(info(e).word==word);assert(xkl_engine_card(e,word)==0);
    assert(!info(e).revealed);assert(!xkl_engine_answer(e,0,++clock));grade(e,0,&clock);
    assert(info(e).first_known==1);assert(info(e).can_undo);assert(xkl_engine_card(e,word)==0x10ffffu);
    assert(xkl_engine_undo(e,++clock));assert(xkl_engine_card(e,word)==0);assert(info(e).word==word);
    size_t n;uint8_t *before=snapshot(e,&n);assert(!xkl_engine_answer(e,9,++clock));assert(!xkl_engine_start(e,17999,clock));
    uint8_t *after=malloc(n);assert(after);assert(xkl_engine_snapshot(e,after,n)==n);assert(!memcmp(before,after,n));
    free(before);free(after);xkl_engine_free(e);puts("PASS reveal gate; question-side familiar; first-known skip; whole-word undo");
}
static unsigned word_tokens(const pocket_state_t *s,uint32_t word,uint8_t *stages) {
    unsigned n=0;for(unsigned i=0;i<s->body.length;++i){const pocket_token_t *t=&s->body.queue[i];if(s->body.active[t->slot].word==word){if(stages)stages[n]=t->stage;++n;}}return n;
}
static void test_wrong_partial_resume(void) {
    xkl_engine_t *e=fresh();int64_t clock=100;assert(xkl_engine_start(e,20745,clock));uint32_t word=info(e).word;
    grade(e,1,&clock);pocket_state_t state=checkpoint(e);uint8_t stages[7];assert(word_tokens(&state,word,stages)==7);
    for(unsigned i=0;i<7;++i)assert(stages[i]==i+1);
    while(info(e).word!=word)grade(e,0,&clock);
    grade(e,3,&clock);state=checkpoint(e);assert(word_tokens(&state,word,stages)==7);for(unsigned i=0;i<7;++i)assert(stages[i]==i+1);
    size_t n;uint8_t *p=snapshot(e,&n);xkl_engine_t *restored=xkl_engine_restore(p,n);assert(restored);free(p);
    pocket_state_t restored_state=checkpoint(restored);assert(!memcmp(&state,&restored_state,sizeof(state)));
    assert(xkl_engine_start(restored,20745,1));assert(!info(restored).revealed);assert(!xkl_engine_answer(restored,0,2));
    restored_state=checkpoint(restored);assert(!memcmp(&state.body,&restored_state.body,sizeof(state.body)));
    int64_t other_clock=10;unsigned seen_stages=0;
    while(info(restored).has_task){if(info(restored).word==word){assert(info(restored).stage==++seen_stages);}grade(restored,0,&other_clock);}
    assert(seen_stages==7);pocket_card_t card=pocket_unpack_card(xkl_engine_card(restored,word));assert(card.level==1&&card.learned&&card.due_day==20746);
    assert(xkl_engine_start(restored,20746,++other_clock));assert(info(restored).review_remaining==1);assert(info(restored).word==word);
    grade(restored,0,&other_clock);card=pocket_unpack_card(xkl_engine_card(restored,word));assert(card.level==2&&card.due_day==20748);
    xkl_engine_free(e);xkl_engine_free(restored);puts("PASS wrong -> partial keeps seven stages; cross-device resume and next-day review");
}
static void test_partial_recheck(void) {
    xkl_engine_t *e=fresh();int64_t clock=100;assert(xkl_engine_start(e,20745,clock));uint32_t word=info(e).word;
    grade(e,3,&clock);pocket_state_t state=checkpoint(e);assert(word_tokens(&state,word,NULL)==1);
    assert(pocket_word_partial_gap(&state,(uint16_t)word)==3);assert(xkl_engine_card(e,word)&POCKET_WORD_PARTIAL_PENDING);
    unsigned intervening=0;while(info(e).word!=word){grade(e,0,&clock);++intervening;}assert(intervening==3);
    assert(info(e).partial_pending);grade(e,0,&clock);uint32_t packed=xkl_engine_card(e,word);
    pocket_card_t c=pocket_unpack_card(packed);assert(c.level==1&&c.learned&&c.due_day==20746&&(packed&POCKET_WORD_PARTIAL_PENDING));
    while(info(e).has_task)grade(e,0,&clock);
    assert(xkl_engine_start(e,20746,++clock));assert(info(e).word==word);assert(info(e).partial_pending);grade(e,0,&clock);
    packed=xkl_engine_card(e,word);c=pocket_unpack_card(packed);assert(c.level==2&&c.due_day==20748&&!(packed&POCKET_WORD_PARTIAL_PENDING));
    xkl_engine_free(e);puts("PASS partial whole-word one queued check, three distinct words, tomorrow repair then normal promotion");
}
static void test_long_term(void) {
    xkl_engine_t *e=fresh();int64_t clock=100;uint32_t day=20745;assert(xkl_engine_start(e,day,clock));uint32_t word=info(e).word;
    grade(e,1,&clock);while(info(e).has_task)grade(e,0,&clock);
    static const unsigned gaps[]={0,1,2,3,5,7,10,15,30,90,180};
    for(unsigned expected_level=2;expected_level<=11;++expected_level){
        pocket_card_t before=pocket_unpack_card(xkl_engine_card(e,word));day=before.due_day;
        assert(xkl_engine_start(e,day,++clock));assert(info(e).word==word);grade(e,0,&clock);
        pocket_card_t after=pocket_unpack_card(xkl_engine_card(e,word));unsigned level=expected_level<10?expected_level:10;
        assert(after.level==level&&after.due_day==day+gaps[level]);while(info(e).has_task)grade(e,0,&clock);
    }
    size_t n;uint8_t *p=snapshot(e,&n);xkl_engine_t *b=xkl_engine_restore(p,n);assert(b);assert(xkl_engine_card(e,word)==xkl_engine_card(b,word));
    free(p);xkl_engine_free(b);xkl_engine_free(e);puts("PASS original long-term intervals through 90/180 days; level 10 repeats at 180 days");
}
static void test_snapshot_validation(void) {
    xkl_engine_t *e=fresh();assert(xkl_engine_start(e,20745,100));assert(xkl_engine_reveal(e,200));size_t n;uint8_t *p=snapshot(e,&n);
    xkl_engine_t *b=xkl_engine_restore(p,n);assert(b);assert(info(b).revealed);assert(!xkl_engine_answer(b,0,199));assert(xkl_engine_answer(b,0,300));xkl_engine_free(b);
    assert(!xkl_engine_restore(p,n-1));p[100]^=1;assert(!xkl_engine_restore(p,n));p[100]^=1;
    put32(p+CARD_OFFSET,0x10ffffu);put32(p+n-4,crc32(p,n-4));assert(!xkl_engine_restore(p,n));
    free(p);p=snapshot(e,&n);p[12]^=1;put32(p+n-4,crc32(p,n-4));assert(!xkl_engine_restore(p,n));
    free(p);p=snapshot(e,&n);p[72]=1;put32(p+n-4,crc32(p,n-4));assert(!xkl_engine_restore(p,n));
    free(p);p=snapshot(e,&n);p[36]&=(uint8_t)~4u;put32(p+n-4,crc32(p,n-4));assert(!xkl_engine_restore(p,n));
    free(p);p=snapshot(e,&n);size_t log_at=CARD_OFFSET+XKL_WORD_COUNT*4u;
    p[log_at+4096+84]^=1;put32(p+n-4,crc32(p,n-4));assert(!xkl_engine_restore(p,n));
    free(p);xkl_engine_free(e);puts("PASS snapshot CRC, foreign version, malformed cards, active/card mismatch and log CRC rejected; rollback preserves reveal");
}
static void test_log_sequence(void) {
    xkl_engine_t *e=fresh();assert(xkl_engine_start(e,20745,100));assert(xkl_engine_reveal(e,200));assert(xkl_engine_reveal(e,250));
    assert(xkl_engine_answer(e,0,300));assert(xkl_engine_undo(e,400));size_t n=xkl_engine_log_size(e);uint8_t *log=malloc(n);assert(log);
    assert(xkl_engine_log(e,log,n)==n);unsigned kinds[]={1,2,3,4,5,3,8,3};assert(info(e).log_records==8);
    for(unsigned i=0;i<8;++i){uint8_t *r=log+4096+i*96;assert(get32(r+4)==i+1);assert(get32(r+8)==kinds[i]);assert(get32(r+76)==3);}
    assert(get32(log+4096+80)==POCKET_EVENT_TIME_UNKNOWN);
    assert(get32(log+4096+6*96+72)==2); /* undo references CORRECT after_revision */
    size_t sn;uint8_t *p=snapshot(e,&sn);xkl_engine_t *b=xkl_engine_restore(p,sn);assert(b);assert(xkl_engine_start(b,20745,1));
    free(log);n=xkl_engine_log_size(b);log=malloc(n);assert(log);assert(xkl_engine_log(b,log,n)==n);
    assert(get32(log+4096+10*96+80)&POCKET_EVENT_RESUME);
    free(log);free(p);xkl_engine_free(b);xkl_engine_free(e);puts("PASS original binary event format, unique monotonic sequence, reveal deduplication, undo link and resume flag");
}
static void test_calendar_rollover_preserves_task(void) {
    xkl_engine_t *e=fresh();int64_t clock=100;
    assert(xkl_engine_start(e,20745,clock));grade(e,1,&clock);
    assert(xkl_engine_reveal(e,++clock));xkl_info_t before=info(e);
    uint32_t *cards=malloc(XKL_WORD_COUNT*sizeof(*cards));assert(cards);
    for(uint32_t i=0;i<XKL_WORD_COUNT;++i)cards[i]=xkl_engine_card(e,i);
    assert(xkl_engine_start(e,20746,++clock));xkl_info_t after=info(e);
    assert(after.day==20746&&after.word==before.word&&after.stage==before.stage);
    assert(after.new_remaining==before.new_remaining&&after.review_remaining==before.review_remaining);
    assert(after.total_remaining==before.total_remaining&&!after.revealed);
    for(uint32_t i=0;i<XKL_WORD_COUNT;++i)assert(cards[i]==xkl_engine_card(e,i));
    /* The admission cutoff now follows the calendar without replacing the
       unfinished task; this fixture has no additional learned cards due. */
    pocket_state_t state=checkpoint(e);assert(state.body.selection_day==20746);
    assert(!xkl_engine_answer(e,0,++clock));
    grade(e,1,&clock);
    pocket_card_t card=pocket_unpack_card(xkl_engine_card(e,after.word));
    assert(card.level==1&&card.due_day==20747);
    free(cards);xkl_engine_free(e);
    puts("PASS calendar rollover preserves unfinished task/cards, hides old answer and schedules from the new day");
}
static xkl_policy_result_t adaptive_grade(xkl_engine_t *e,int answer,int64_t *clock,uint32_t first) {
    xkl_policy_result_t result;
    assert(xkl_engine_reveal(e,++*clock));
    assert(xkl_engine_answer_conservative(e,answer,++*clock,true,first,&result));return result;
}
static void test_conservative_completion(void) {
    xkl_engine_t *e=fresh();int64_t clock=100;assert(xkl_engine_start(e,20745,clock));
    uint32_t word=info(e).word,first=info(e).log_records+1;
    grade(e,1,&clock);unsigned recalls=0,removed=0;
    size_t old_size=xkl_engine_log_size(e);uint8_t *old=malloc(old_size);assert(old);
    assert(xkl_engine_log(e,old,old_size)==old_size);
    while(info(e).has_task){
        xkl_info_t current=info(e);xkl_policy_result_t result=adaptive_grade(e,0,&clock,first);
        if(current.word==word){
            ++recalls;
            if(result.removed){
                assert(current.stage==5&&result.removed==2&&result.qualified_recalls==3);
                assert(result.distinct_gap>=7&&result.long_gap==1);removed+=result.removed;
                xkl_event_info_t event;assert(xkl_engine_event(e,result.answer_sequence-1,&event));
                assert(event.word==word&&event.kind==5&&event.after_revision==result.after_revision);
            }
            if(current.stage==3){ /* Real restart keeps evidence in the existing log. */
                size_t n;uint8_t *bytes=snapshot(e,&n);xkl_engine_t *restored=xkl_engine_restore(bytes,n);assert(restored);
                free(bytes);xkl_engine_free(e);e=restored;assert(xkl_engine_start(e,20745,++clock));
            }
        }
    }
    assert(recalls==5&&removed==2);
    size_t n=xkl_engine_log_size(e);uint8_t *now=malloc(n);assert(now);assert(xkl_engine_log(e,now,n)==n);
    assert(!memcmp(old,now,old_size));free(old);free(now);
    pocket_card_t card=pocket_unpack_card(xkl_engine_card(e,word));
    assert(card.level==1&&card.learned&&!card.familiar&&card.due_day==20746);
    assert(xkl_engine_start(e,20746,++clock));assert(info(e).word==word);
    adaptive_grade(e,1,&clock,first);pocket_state_t state=checkpoint(e);uint8_t stages[7];
    assert(word_tokens(&state,word,stages)==7);for(unsigned i=0;i<7;++i)assert(stages[i]==i+1);
    xkl_engine_free(e);puts("PASS conservative 3/3/7 evidence: stage 5 removes 2; restart and log prefix preserved; tomorrow wrong restores 7");
}
static void test_conservative_exclusions(void) {
    for(unsigned mode=0;mode<5;++mode){
        xkl_engine_t *e=fresh();int64_t clock=100;assert(xkl_engine_start(e,20745,clock));
        uint32_t word=info(e).word,first=info(e).log_records+1;grade(e,1,&clock);
        unsigned removed=0,recalls=0;bool reset=false;
        while(info(e).has_task){
            xkl_info_t current=info(e);
            if(current.word==word&&current.stage==4&&!reset){
                if(mode==1){ /* Partial clears credit, keeps all outstanding reinforcement. */
                    pocket_state_t before=checkpoint(e);unsigned pending=word_tokens(&before,word,NULL);
                    adaptive_grade(e,3,&clock,first);pocket_state_t after=checkpoint(e);
                    assert(word_tokens(&after,word,NULL)==pending);reset=true;continue;
                }
                if(mode==2){first=info(e).log_records+1;reset=true;}
            }
            if(mode==3&&current.word!=word&&recalls>=3&&!reset){
                grade(e,0,&clock);assert(xkl_engine_undo(e,++clock));reset=true;continue;
            }
            if(current.word==word)++recalls;
            if(mode==0&&current.word!=word){grade(e,2,&clock);continue;} /* Familiar is not recall evidence. */
            if(mode==4){grade(e,0,&clock);continue;} /* Disabled: original seven stages. */
            removed+=adaptive_grade(e,0,&clock,first).removed;
        }
        assert(removed==0&&recalls==7);xkl_engine_free(e);
    }
    puts("PASS short tails/familiar, partial, activation cutoff, undo and disabled policy cannot claim interval successes");
}
static void compare_progress(xkl_engine_t *a,xkl_engine_t *b) {
    pocket_state_t x=checkpoint(a),y=checkpoint(b);assert(!memcmp(&x,&y,sizeof(x)));
    xkl_info_t ia=info(a),ib=info(b);assert(!memcmp(&ia,&ib,sizeof(ia)));
    for(uint32_t i=0;i<XKL_WORD_COUNT;++i) assert(xkl_engine_card(a,i)==xkl_engine_card(b,i));
}
static void rotate_restore(xkl_engine_t **engine,uint32_t first) {
    xkl_engine_t *e=*engine;size_t n;uint8_t *old=snapshot(e,&n);
    uint32_t before=info(e).log_records;assert(xkl_engine_rotate_log(e,first));
    assert(info(e).log_records==before);assert(xkl_engine_log_base(e)==before);
    assert(xkl_engine_volume_records(e)<=3);size_t count;uint8_t *now=snapshot(e,&count);
    assert(get32(now+4)==2);xkl_engine_t *restored=xkl_engine_restore(now,count);assert(restored);
    assert(get32(old+n-4)==crc32(old,n-4));free(old);free(now);xkl_engine_free(e);*engine=restored;
}
static void test_rotation_preserves_every_learning_transition(void) {
    xkl_engine_t *reference=fresh(),*rotated=fresh();int64_t clock=100;
    assert(xkl_engine_start(reference,20745,clock));assert(xkl_engine_start(rotated,20745,clock));
    uint32_t first=info(reference).log_records+1;unsigned turns=0,reductions=0;
    while(info(reference).has_task) {
        assert(xkl_engine_reveal(reference,++clock));assert(xkl_engine_reveal(rotated,clock));
        if(turns%3==0) rotate_restore(&rotated,first);
        compare_progress(reference,rotated);
        xkl_policy_result_t a,b;int answer=turns==0 ? 1:0;
        assert(xkl_engine_answer_conservative(reference,answer,++clock,true,first,&a));
        assert(xkl_engine_answer_conservative(rotated,answer,clock,true,first,&b));
        assert(!memcmp(&a,&b,sizeof(a)));reductions+=a.removed;
        compare_progress(reference,rotated);
        xkl_event_info_t ea,eb;assert(xkl_engine_event(reference,a.answer_sequence-1,&ea));
        assert(xkl_engine_event(rotated,b.answer_sequence-1,&eb));assert(!memcmp(&ea,&eb,sizeof(ea)));
        ++turns;
    }
    assert(reductions==2);rotate_restore(&rotated,first);compare_progress(reference,rotated);
    assert(xkl_engine_start(reference,20746,++clock));assert(xkl_engine_start(rotated,20746,clock));
    compare_progress(reference,rotated);
    xkl_engine_free(reference);xkl_engine_free(rotated);
    puts("PASS repeated mid-answer rotations and restarts preserve all cards, queue, reveal, timestamps, global IDs and exact reduction decisions");
}
static void test_rotation_undo_and_real_capacity(void) {
    xkl_engine_t *e=fresh();int64_t clock=100;assert(xkl_engine_start(e,20745,clock));
    grade(e,2,&clock);uint32_t total=info(e).log_records;rotate_restore(&e,1);
    assert(xkl_engine_undo(e,++clock));xkl_event_info_t undo;
    assert(xkl_engine_event(e,total,&undo));assert(undo.kind==8&&undo.undo_revision!=UINT32_MAX);
    unsigned volumes=0;
    while(info(e).log_records<POCKET_LOG_CAPACITY+25u) {
        if(xkl_engine_volume_records(e)>=POCKET_LOG_CAPACITY-4u) { rotate_restore(&e,1);++volumes; }
        assert(xkl_engine_start(e,20745,++clock));
    }
    assert(volumes>0);assert(info(e).has_task);grade(e,1,&clock);
    pocket_state_t state=checkpoint(e);assert(word_tokens(&state,0,NULL)==7);
    xkl_engine_free(e);puts("PASS cross-volume undo reference and continued learning beyond 21,802 real events");
    e=fresh();clock=100;assert(xkl_engine_start(e,20745,clock));
    while(xkl_engine_volume_records(e)+3u<=POCKET_LOG_CAPACITY) assert(xkl_engine_start(e,20745,++clock));
    assert(xkl_engine_volume_records(e)+1u==POCKET_LOG_CAPACITY);assert(xkl_engine_reveal(e,++clock));
    assert(!xkl_engine_answer(e,1,++clock)); /* Old full archive cannot append. */
    rotate_restore(&e,1);assert(info(e).revealed);assert(xkl_engine_answer(e,1,++clock));
    state=checkpoint(e);assert(word_tokens(&state,0,NULL)==7);
    xkl_engine_free(e);puts("PASS upgrade recovery from an exactly full legacy log, retaining the revealed answer and seven-stage recovery");
}
int main(int argc,char **argv) {
    assert(argc==1 || argc==2);if(argc==2) test_personal(argv[1]);test_reveal_undo();test_wrong_partial_resume();test_partial_recheck();test_long_term();test_snapshot_validation();test_log_sequence();test_calendar_rollover_preserves_task();
    test_conservative_completion();test_conservative_exclusions();
    test_rotation_preserves_every_learning_transition();test_rotation_undo_and_real_capacity();
    puts("PASS all CPocket engine tests");return 0;
}
