#include "pocket_storage.h"
#include <string.h>

#define BANK_MAGIC UINT32_C(0x584b424b)
#define RECORD_MAGIC UINT32_C(0x584b5458)
#define FORMAT_VERSION 2u
#define COMMITTED UINT32_C(0x434f4d54)
#define ERASED UINT32_MAX
#define BANK_HEADER_BYTES 64u
#define RECORD_HEADER_BYTES 32u

/* Disk structures are fixed little-endian uint32 words. The target and host
 * tests are little-endian. No compiler-dependent C structure is persisted. */
static uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
        ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void put32(uint8_t *p, uint32_t v) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(v >> (i * 8));
}
static uint32_t crc_update(uint32_t crc, const void *bytes, size_t length) {
    const uint8_t *p = bytes;
    while (length--) {
        crc ^= *p++;
        for (unsigned i = 0; i < 8; ++i)
            crc = (crc >> 1) ^ (UINT32_C(0xedb88320) & (0u - (crc & 1u)));
    }
    return crc;
}
static uint32_t crc32(const void *p, size_t n) { return ~crc_update(UINT32_MAX, p, n); }
static uint32_t align_page(uint32_t n) {
    return (n + POCKET_STORAGE_PAGE - 1) & ~(POCKET_STORAGE_PAGE - 1);
}
static bool read_at(pocket_storage_t *s, uint32_t at, void *p, size_t n) {
    if (at > s->io.size || n > s->io.size - at || !s->io.read(s->io.context, at, p, n)) {
        s->failed = true; return false;
    }
    return true;
}
static bool write_at(pocket_storage_t *s, uint32_t at, const void *p, size_t n) {
    if (at > s->io.size || n > s->io.size - at || !s->io.write(s->io.context, at, p, n)) {
        s->failed = true; return false;
    }
    return true;
}
static bool erase_at(pocket_storage_t *s, uint32_t at, size_t n) {
    if (!s->io.erase(s->io.context, at, n)) { s->failed = true; return false; }
    return true;
}
static bool disk_crc(pocket_storage_t *s, uint32_t at, uint32_t n, uint32_t *out) {
    uint32_t crc = UINT32_MAX;
    s->cached_page = ERASED;
    while (n) {
        uint32_t take = n < sizeof(s->scratch) ? n : sizeof(s->scratch);
        if (!read_at(s, at, s->scratch, take)) return false;
        crc = crc_update(crc, s->scratch, take);
        at += take; n -= take;
    }
    *out = ~crc;
    return true;
}
static bool verify_bytes(pocket_storage_t *s, uint32_t at, const void *bytes, uint32_t n) {
    uint32_t actual;
    if (!disk_crc(s, at, n, &actual) || actual != crc32(bytes, n)) {
        s->failed = true; return false;
    }
    return true;
}
static bool blank(const uint8_t *p, size_t n) {
    while (n--) if (*p++ != 0xff) return false;
    return true;
}
static bool all_erased(pocket_storage_t *s) {
    s->cached_page = ERASED;
    for (uint32_t at = 0; at < s->io.size; at += POCKET_STORAGE_PAGE) {
        if (!read_at(s, at, s->scratch, sizeof(s->scratch)) ||
            !blank(s->scratch, sizeof(s->scratch))) return false;
    }
    return true;
}
static bool index_put(pocket_storage_t *s, uint32_t id, uint32_t value) {
    if (id == POCKET_STORAGE_NO_CARD) return true;
    for (uint32_t i = 0; i < s->entry_count; ++i) {
        if (s->entries[i].id == id) { s->entries[i].value = value; return true; }
    }
    if (s->entry_count >= POCKET_STORAGE_JOURNAL_MAX) return false;
    s->entries[s->entry_count++] = (pocket_storage_entry_t){id, value};
    return true;
}

/* 0: not committed; 1: intact compatible bank; -1: committed but invalid. */
static int bank_header(pocket_storage_t *s, uint32_t bank, uint8_t header[64]) {
    uint32_t offset = bank * s->bank_size, actual;
    if (!read_at(s, offset, header, BANK_HEADER_BYTES)) return -1;
    if (get32(header + 60) != COMMITTED) return 0;
    if (get32(header) != BANK_MAGIC || get32(header + 4) != FORMAT_VERSION ||
        get32(header + 8) != s->deck_id || get32(header + 12) != s->card_count ||
        get32(header + 16) != s->checkpoint_size || get32(header + 36) != s->bank_size ||
        !get32(header + 20) || get32(header + 56) != crc32(header, 56)) return -1;
    if (!disk_crc(s, offset + POCKET_STORAGE_PAGE, s->base_size, &actual) ||
        actual != get32(header + 28)) return -1;
    if (!disk_crc(s, offset + s->checkpoint_offset, s->checkpoint_size, &actual) ||
        actual != get32(header + 32)) return -1;
    return 1;
}

static bool scan_records(pocket_storage_t *s, void *checkpoint) {
    const uint32_t base = s->bank * s->bank_size + s->journal_offset;
    uint8_t header[RECORD_HEADER_BYTES], marker[4];
    s->entry_count = 0; s->next_slot = 0;
    for (uint32_t slot = 0; slot < s->slot_count; ++slot) {
        uint32_t at = base + slot * POCKET_STORAGE_PAGE;
        if (!read_at(s, at, header, sizeof(header)) ||
            !read_at(s, at + POCKET_STORAGE_PAGE - 4, marker, 4)) return false;
        if (!blank(header, sizeof(header)) || !blank(marker, 4)) s->next_slot = slot + 1;
        if (get32(marker) != COMMITTED) continue; /* interrupted append, slot is consumed */
        uint32_t actual, id = get32(header + 8), seq = get32(header + 4);
        if (get32(header) != RECORD_MAGIC || get32(header + 16) != s->checkpoint_size ||
            get32(header + 28) != crc32(header, 28) ||
            seq != s->sequence + 1 || s->sequence == UINT32_MAX ||
            (id >= s->card_count && id != POCKET_STORAGE_NO_CARD) ||
            !disk_crc(s, at + RECORD_HEADER_BYTES, s->checkpoint_size, &actual) ||
            actual != get32(header + 20)) return false;
        if (!read_at(s, at + RECORD_HEADER_BYTES, checkpoint, s->checkpoint_size) ||
            !index_put(s, id, get32(header + 12))) return false;
        s->sequence = seq;
    }
    return true;
}

pocket_storage_result_t pocket_storage_open(pocket_storage_t *s,
    pocket_storage_io_t io, uint32_t deck_id, uint32_t card_count,
    size_t checkpoint_size, void *checkpoint) {
    if (!s || !checkpoint) return POCKET_STORAGE_ERROR;
    memset(s, 0, sizeof(*s)); s->io = io; s->cached_page = ERASED;
    if (!io.read || !io.write || !io.erase || !card_count ||
        card_count > io.size / 8u || !checkpoint_size ||
        checkpoint_size > POCKET_STORAGE_CHECKPOINT_MAX || io.size > UINT32_C(0x200000) ||
        io.size % (2 * POCKET_STORAGE_PAGE)) { s->failed = true; return POCKET_STORAGE_ERROR; }
    s->deck_id = deck_id; s->card_count = card_count;
    s->checkpoint_size = (uint32_t)checkpoint_size; s->bank_size = io.size / 2;
    s->base_size = align_page((uint32_t)card_count * 4);
    s->checkpoint_offset = POCKET_STORAGE_PAGE + s->base_size;
    s->journal_offset = s->checkpoint_offset + POCKET_STORAGE_PAGE;
    if (s->journal_offset >= s->bank_size) { s->failed = true; return POCKET_STORAGE_ERROR; }
    s->slot_count = (s->bank_size - s->journal_offset) / POCKET_STORAGE_PAGE;
    if (s->slot_count > POCKET_STORAGE_JOURNAL_MAX) { s->failed = true; return POCKET_STORAGE_ERROR; }
    uint8_t a[64], b[64];
    int va = bank_header(s, 0, a), vb = bank_header(s, 1, b);
    if (va < 0 || vb < 0) { s->failed = true; return POCKET_STORAGE_ERROR; }
    if (!va && !vb) {
        if (all_erased(s)) { s->empty = true; return POCKET_STORAGE_EMPTY; }
        s->failed = true; return POCKET_STORAGE_ERROR;
    }
    if (va && vb && get32(a + 20) == get32(b + 20)) { s->failed = true; return POCKET_STORAGE_ERROR; }
    s->bank = va && (!vb || get32(a + 20) > get32(b + 20)) ? 0 : 1;
    const uint8_t *chosen = s->bank ? b : a;
    s->generation = get32(chosen + 20); s->sequence = get32(chosen + 24);
    if (!read_at(s, s->bank * s->bank_size + s->checkpoint_offset, checkpoint, s->checkpoint_size) ||
        !scan_records(s, checkpoint)) { s->failed = true; return POCKET_STORAGE_ERROR; }
    s->ready = true;
    return POCKET_STORAGE_READY;
}

bool pocket_storage_card(pocket_storage_t *s, uint32_t id, uint32_t *value) {
    if (!s || !value || !s->ready || s->failed || id >= s->card_count) return false;
    for (uint32_t i = 0; i < s->entry_count; ++i)
        if (s->entries[i].id == id) { *value = s->entries[i].value; return true; }
    uint32_t byte = (uint32_t)id * 4;
    uint32_t page = s->bank * s->bank_size + POCKET_STORAGE_PAGE +
                    (byte & ~(POCKET_STORAGE_PAGE - 1));
    if (s->cached_page != page) {
        if (!read_at(s, page, s->scratch, sizeof(s->scratch))) return false;
        s->cached_page = page;
    }
    *value = get32(s->scratch + byte % POCKET_STORAGE_PAGE);
    return true;
}

/* Build the inactive bank completely, then publish only its final commit word.
 * Its predecessor is not erased here and remains a recovery point throughout. */
static bool build_bank(pocket_storage_t *s, const void *checkpoint,
                       uint32_t changed_id, uint32_t value, bool initial) {
    if ((!initial && s->generation == UINT32_MAX) || s->sequence == UINT32_MAX) return false;
    uint32_t target = initial ? 0 : 1 - s->bank, start = target * s->bank_size;
    s->cached_page = ERASED;
    /* Retire the inactive header before erasing it. A torn sector erase may
     * otherwise retain its commit word while damaging other header fields. */
    const uint8_t retired[4] = {0, 0, 0, 0};
    if (!write_at(s, start + 60, retired, sizeof(retired)) ||
        !verify_bytes(s, start + 60, retired, sizeof(retired)) ||
        !erase_at(s, start, POCKET_STORAGE_PAGE) ||
        !erase_at(s, start + POCKET_STORAGE_PAGE, s->bank_size - POCKET_STORAGE_PAGE)) return false;
    uint32_t crc = UINT32_MAX;
    for (uint32_t offset = 0; offset < s->base_size; offset += POCKET_STORAGE_PAGE) {
        if (initial) memset(s->scratch, 0, sizeof(s->scratch));
        else if (!read_at(s, s->bank * s->bank_size + POCKET_STORAGE_PAGE + offset,
                          s->scratch, sizeof(s->scratch))) return false;
        for (uint32_t i = 0; i < s->entry_count; ++i) {
            uint32_t byte = s->entries[i].id * 4;
            if (byte >= offset && byte < offset + POCKET_STORAGE_PAGE)
                put32(s->scratch + byte - offset, s->entries[i].value);
        }
        uint32_t changed_byte = (uint32_t)changed_id * 4;
        if (changed_id != POCKET_STORAGE_NO_CARD && changed_byte >= offset &&
            changed_byte < offset + POCKET_STORAGE_PAGE)
            put32(s->scratch + changed_byte - offset, value);
        crc = crc_update(crc, s->scratch, sizeof(s->scratch));
        if (!write_at(s, start + POCKET_STORAGE_PAGE + offset, s->scratch, sizeof(s->scratch))) return false;
    }
    uint32_t expected_base_crc = ~crc, actual;
    if (!disk_crc(s, start + POCKET_STORAGE_PAGE, s->base_size, &actual) ||
        actual != expected_base_crc) { s->failed = true; return false; }
    if (!write_at(s, start + s->checkpoint_offset, checkpoint, s->checkpoint_size) ||
        !verify_bytes(s, start + s->checkpoint_offset, checkpoint, s->checkpoint_size)) return false;
    uint8_t header[64]; memset(header, 0, sizeof(header));
    put32(header, BANK_MAGIC); put32(header + 4, FORMAT_VERSION);
    put32(header + 8, s->deck_id); put32(header + 12, s->card_count);
    put32(header + 16, s->checkpoint_size);
    put32(header + 20, initial ? 1 : s->generation + 1);
    put32(header + 24, initial ? 0 : s->sequence + 1);
    put32(header + 28, expected_base_crc);
    put32(header + 32, crc32(checkpoint, s->checkpoint_size));
    put32(header + 36, s->bank_size);
    put32(header + 56, crc32(header, 56)); put32(header + 60, ERASED);
    if (!write_at(s, start, header, 60) || !verify_bytes(s, start, header, 60)) return false;
    put32(header + 60, COMMITTED);
    if (!write_at(s, start + 60, header + 60, 4) ||
        !verify_bytes(s, start + 60, header + 60, 4)) return false;
    s->bank = target; s->generation = get32(header + 20); s->sequence = get32(header + 24);
    s->entry_count = 0; s->next_slot = 0; s->cached_page = ERASED;
    s->ready = true; s->empty = false;
    return true;
}

bool pocket_storage_create(pocket_storage_t *s, const void *checkpoint) {
    if (!s || !checkpoint || s->failed || !s->empty || s->ready) return false;
    return build_bank(s, checkpoint, POCKET_STORAGE_NO_CARD, 0, true);
}

bool pocket_storage_commit(pocket_storage_t *s, const void *checkpoint,
                           uint32_t changed_id, uint32_t value) {
    if (!s || !checkpoint || !s->ready || s->failed || s->sequence == UINT32_MAX ||
        (changed_id >= s->card_count && changed_id != POCKET_STORAGE_NO_CARD)) return false;
    if (s->next_slot == s->slot_count) return build_bank(s, checkpoint, changed_id, value, false);
    uint32_t at = s->bank * s->bank_size + s->journal_offset +
                  s->next_slot * POCKET_STORAGE_PAGE;
    uint8_t header[RECORD_HEADER_BYTES]; memset(header, 0, sizeof(header));
    put32(header, RECORD_MAGIC); put32(header + 4, s->sequence + 1);
    put32(header + 8, changed_id); put32(header + 12, value);
    put32(header + 16, s->checkpoint_size);
    put32(header + 20, crc32(checkpoint, s->checkpoint_size));
    put32(header + 28, crc32(header, 28));
    s->cached_page = ERASED;
    if (!write_at(s, at, header, sizeof(header)) ||
        !write_at(s, at + RECORD_HEADER_BYTES, checkpoint, s->checkpoint_size) ||
        !verify_bytes(s, at, header, sizeof(header)) ||
        !verify_bytes(s, at + RECORD_HEADER_BYTES, checkpoint, s->checkpoint_size)) return false;
    uint8_t marker[4]; put32(marker, COMMITTED);
    if (!write_at(s, at + POCKET_STORAGE_PAGE - 4, marker, 4) ||
        !verify_bytes(s, at + POCKET_STORAGE_PAGE - 4, marker, 4)) return false;
    ++s->next_slot; ++s->sequence;
    if (!index_put(s, changed_id, value)) { s->failed = true; return false; }
    return true;
}
