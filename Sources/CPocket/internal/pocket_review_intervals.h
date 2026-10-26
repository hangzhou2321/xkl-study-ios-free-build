#pragma once
#include <stdint.h>
/* The existing word-model table, shared without changing its values or
 * graduation rules. Learning-skill evidence is kept outside the word model. */
static inline uint16_t pocket_review_interval_days(unsigned level) {
    static const uint16_t gaps[] = {0,1,2,3,5,7,10,15,30,90,180};
    return level <= 10u ? gaps[level] : 0;
}
