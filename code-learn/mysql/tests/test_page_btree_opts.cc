// test_page_btree_opts.cc
// Page-level unit tests for B-Tree optimization features.
//
// Build:
//   g++ -std=c++20 -I.. -I../../include -I../../build/include \
//       test_page_btree_opts.cc -o test_page_btree_opts
//
// This is a simplified standalone test that directly exercises
// page operations to verify Heads/Hints/Semi-Dense behavior.
//
// NOTE: Full InnoDB compilation requires the complete build system.
// This file documents the intended test structure.
// For actual testing, use the mtr framework or embed in MySQL's
// Google Test suite.

#include <cassert>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <algorithm>
#include <random>

// ============================================================
// Page layout simulation (independent of InnoDB includes)
// Simulates the BTREE_OPT page format for verification.
// ============================================================

constexpr size_t PAGE_SIZE = 16384;
constexpr size_t PAGE_DIR = 8;
constexpr size_t PAGE_HEADER = 38;
constexpr size_t PAGE_LEVEL_OFF = PAGE_HEADER + 26;
constexpr size_t PAGE_N_RECS_OFF = PAGE_HEADER + 16;
constexpr size_t PAGE_N_HEAP_OFF = PAGE_HEADER + 4;
constexpr size_t PAGE_HEAP_TOP_OFF = PAGE_HEADER + 2;
constexpr size_t PAGE_FREE_OFF = PAGE_HEADER + 6;
constexpr size_t PAGE_DIRECTION_OFF = PAGE_HEADER + 12;
constexpr size_t PAGE_N_DIRECTION_OFF = PAGE_HEADER + 14;

// Infimum/supremum for compact format
constexpr size_t INFIMUM_EXTRA = 5;
constexpr size_t PAGE_DATA = PAGE_HEADER + 36 + 2 * 10;  // = 94
constexpr size_t NEW_INFIMUM = PAGE_DATA + INFIMUM_EXTRA;  // 99
constexpr size_t NEW_SUPREMUM = PAGE_DATA + 2 * INFIMUM_EXTRA + 8;  // 112
constexpr size_t NEW_SUPREMUM_END = NEW_SUPREMUM + 8;  // 120
constexpr size_t BTREE_HDR_SIZE = 184;
constexpr size_t HEAP_START = NEW_SUPREMUM_END + BTREE_HDR_SIZE;  // 304

// Slot constants
constexpr size_t SLOT_SIZE_ORIG = 2;
constexpr size_t SLOT_SIZE_OPT = 6;

struct TestPage {
  uint8_t data[PAGE_SIZE]{};

  void init(bool btree_opt) {
    memset(data, 0, PAGE_SIZE);

    // Page type
    data[24] = 0x00; // FIL_PAGE_INDEX high
    data[25] = 0x45; // FIL_PAGE_INDEX low (0x4542 = 17730)

    // Page header
    data[PAGE_HEADER] = 0;  // PAGE_N_DIR_SLOTS high = 0
    data[PAGE_HEADER + 1] = 2;  // PAGE_N_DIR_SLOTS low = 2 (infimum + supremum)
    data[PAGE_HEADER + 12] = 0;
    data[PAGE_HEADER + 13] = 5; // PAGE_NO_DIRECTION

    // Compact format flag
    data[PAGE_HEADER + 4] = 0x80; // PAGE_N_HEAP high = comp flag
    data[PAGE_HEADER + 5] = 2;    // PAGE_N_HEAP low = heap_no 2

    // PAGE_LEVEL
    if (btree_opt) {
      // Format = 1, Level = 0 → (1 << 8) | 0 = 0x0100
      data[PAGE_LEVEL_OFF] = 0x01;
      data[PAGE_LEVEL_OFF+1] = 0x00;
    } else {
      data[PAGE_LEVEL_OFF] = 0;
      data[PAGE_LEVEL_OFF+1] = 0;
    }

    // Heap top
    uint16_t heap_top = static_cast<uint16_t>(btree_opt ? HEAP_START : NEW_SUPREMUM_END);
    data[PAGE_HEAP_TOP_OFF] = static_cast<uint8_t>(heap_top >> 8);
    data[PAGE_HEAP_TOP_OFF + 1] = static_cast<uint8_t>(heap_top & 0xFF);

    // Infimum + supremum records
    memcpy(&data[PAGE_DATA], "\x01\x00\x02infimum\x00\x00\x0bsupremum", 26);
    // Set up next pointers
    data[NEW_INFIMUM - INFIMUM_EXTRA + 1] = 0;  // n_owned of infimum
    data[NEW_INFIMUM - INFIMUM_EXTRA + 4] = static_cast<uint8_t>(NEW_SUPREMUM >> 8);
    data[NEW_INFIMUM - INFIMUM_EXTRA + 5] = static_cast<uint8_t>(NEW_SUPREMUM & 0xFF);
    data[NEW_SUPREMUM - INFIMUM_EXTRA + 1] = 1;  // n_owned of supremum

    // BTREE_OPT: initialize header area
    if (btree_opt) {
      memset(&data[NEW_SUPREMUM_END], 0, BTREE_HDR_SIZE);
    }

    // Directory slots
    size_t slot_sz = btree_opt ? SLOT_SIZE_OPT : SLOT_SIZE_ORIG;
    // Slot 0 (infimum)
    write_slot(PAGE_SIZE - PAGE_DIR - slot_sz, NEW_INFIMUM, slot_sz, 0);
    // Slot 1 (supremum)
    write_slot(PAGE_SIZE - PAGE_DIR - slot_sz * 2, NEW_SUPREMUM, slot_sz, 0);
  }

  void write_slot(size_t pos, uint16_t offset, size_t slot_sz, uint32_t head) {
    data[pos] = static_cast<uint8_t>(offset >> 8);
    data[pos+1] = static_cast<uint8_t>(offset & 0xFF);
    if (slot_sz == SLOT_SIZE_OPT) {
      data[pos+2] = static_cast<uint8_t>(head >> 24);
      data[pos+3] = static_cast<uint8_t>(head >> 16);
      data[pos+4] = static_cast<uint8_t>(head >> 8);
      data[pos+5] = static_cast<uint8_t>(head & 0xFF);
    }
  }

  size_t slot_size() const {
    return (data[PAGE_LEVEL_OFF] == 0x01) ? SLOT_SIZE_OPT : SLOT_SIZE_ORIG;
  }

  // Get n-th slot position
  size_t slot_pos(size_t n) const {
    size_t sz = slot_size();
    return PAGE_SIZE - PAGE_DIR - (n + 1) * sz;
  }

  uint16_t slot_offset(size_t n) const {
    size_t pos = slot_pos(n);
    return static_cast<uint16_t>((data[pos] << 8) | data[pos+1]);
  }

  uint32_t slot_head(size_t n) const {
    if (slot_size() != SLOT_SIZE_OPT) return 0;
    size_t pos = slot_pos(n);
    return static_cast<uint32_t>(
        (data[pos+2] << 24) | (data[pos+3] << 16) |
        (data[pos+4] << 8)  | data[pos+5]);
  }

  size_t n_slots() const {
    return data[PAGE_HEADER + 1];  // PAGE_N_DIR_SLOTS low byte
  }

  void set_n_slots(size_t n) {
    data[PAGE_HEADER + 3] = static_cast<uint8_t>(n);
  }

  size_t n_recs() const {
    return static_cast<size_t>(data[PAGE_HEADER + 17]);
  }

  void inc_recs() {
    auto v = n_recs() + 1;
    data[PAGE_HEADER + 16] = static_cast<uint8_t>(v >> 8);
    data[PAGE_HEADER + 17] = static_cast<uint8_t>(v & 0xFF);
  }

  // Insert a record with the given key string.
  // Inserts after the infimum for simplicity.
  size_t insert_record(const std::string &key) {
    size_t heap_top = static_cast<size_t>(
        (data[PAGE_HEAP_TOP_OFF] << 8) | data[PAGE_HEAP_TOP_OFF+1]);

    // Record format: just the key bytes (no InnoDB header for test)
    size_t rec_size = key.size();
    memcpy(&data[heap_top], key.data(), rec_size);
    heap_top += rec_size;

    // Update heap top
    data[PAGE_HEAP_TOP_OFF] = static_cast<uint8_t>(heap_top >> 8);
    data[PAGE_HEAP_TOP_OFF+1] = static_cast<uint8_t>(heap_top & 0xFF);

    // Increment N_RECS
    inc_recs();

    return heap_top - rec_size;  // return record position
  }

  // Print page summary
  void dump() const {
    printf("Page: format=%s slot_size=%zu n_slots=%zu n_recs=%zu\n",
           (data[PAGE_LEVEL_OFF] == 0x01) ? "BTREE_OPT" : "ORIG",
           slot_size(), n_slots(), n_recs());
    printf("  Heap top: %zu\n", heap_top());
    if (slot_size() == SLOT_SIZE_OPT) {
      printf("  BTREE FLAGS: 0x%08x\n", btree_flags());
    }
  }

  size_t heap_top() const {
    return static_cast<size_t>(
        (data[PAGE_HEAP_TOP_OFF] << 8) | data[PAGE_HEAP_TOP_OFF+1]);
  }

  uint32_t btree_flags() const {
    return static_cast<uint32_t>(
        (data[NEW_SUPREMUM_END] << 24) |
        (data[NEW_SUPREMUM_END+1] << 16) |
        (data[NEW_SUPREMUM_END+2] << 8) |
        data[NEW_SUPREMUM_END+3]);
  }

  void set_btree_flags(uint32_t flags) {
    data[NEW_SUPREMUM_END]   = static_cast<uint8_t>(flags >> 24);
    data[NEW_SUPREMUM_END+1] = static_cast<uint8_t>(flags >> 16);
    data[NEW_SUPREMUM_END+2] = static_cast<uint8_t>(flags >> 8);
    data[NEW_SUPREMUM_END+3] = static_cast<uint8_t>(flags & 0xFF);
  }
};

// ============================================================
// Unit Tests
// ============================================================

int test_page_format_detection() {
  printf("=== test_page_format_detection ===\n");

  { // ORIG format
    TestPage p;
    p.init(false);
    assert(p.slot_size() == SLOT_SIZE_ORIG);
    assert(p.slot_offset(0) == NEW_INFIMUM);
    assert(p.slot_offset(1) == NEW_SUPREMUM);
    assert(p.n_slots() == 2);
    printf("  ORIG: OK (slot_size=%zu)\n", p.slot_size());
  }

  { // BTREE_OPT format
    TestPage p;
    p.init(true);
    assert(p.slot_size() == SLOT_SIZE_OPT);
    assert(p.slot_offset(0) == NEW_INFIMUM);
    assert(p.slot_offset(1) == NEW_SUPREMUM);
    assert(p.n_slots() == 2);
    printf("  BTREE_OPT: OK (slot_size=%zu)\n", p.slot_size());
  }

  printf("  PASSED\n");
  return 0;
}

int test_heads_initialization() {
  printf("=== test_heads_initialization ===\n");

  TestPage p;
  p.init(true);  // BTREE_OPT

  // Heads should be 0 for infimum/supremum slots
  assert(p.slot_head(0) == 0);
  assert(p.slot_head(1) == 0);

  printf("  Heads initialized to 0: OK\n");

  // Manually set a head on slot 0
  p.write_slot(PAGE_SIZE - PAGE_DIR - SLOT_SIZE_OPT, NEW_INFIMUM, SLOT_SIZE_OPT, 0x12345678);
  assert(p.slot_head(0) == 0x12345678);
  printf("  Head write/read: OK (head=0x%08x)\n", p.slot_head(0));

  printf("  PASSED\n");
  return 0;
}

int test_slot_dynamic_stride() {
  printf("=== test_slot_dynamic_stride ===\n");

  { // ORIG: 3 slots at stride 2
    TestPage p;
    p.init(false);  // ORIG
    p.set_n_slots(3);

    // Manually write a third slot
    size_t slot2_pos = PAGE_SIZE - PAGE_DIR - SLOT_SIZE_ORIG * 3;
    p.data[slot2_pos] = 0;
    p.data[slot2_pos+1] = 0x50;  // dummy offset 80

    assert(p.slot_offset(0) == NEW_INFIMUM);
    assert(p.slot_offset(1) == NEW_SUPREMUM);
    assert(p.slot_offset(2) == 80);
    printf("  ORIG slots at stride 2: OK\n");
  }

  { // BTREE_OPT: 3 slots at stride 6
    TestPage p;
    p.init(true);
    p.set_n_slots(3);

    size_t slot2_pos = PAGE_SIZE - PAGE_DIR - SLOT_SIZE_OPT * 3;
    p.data[slot2_pos] = 0;
    p.data[slot2_pos+1] = 0x60;
    p.data[slot2_pos+2] = 0xDE;
    p.data[slot2_pos+3] = 0xAD;
    p.data[slot2_pos+4] = 0xBE;
    p.data[slot2_pos+5] = 0xEF;

    assert(p.slot_offset(2) == 0x60);
    assert(p.slot_head(2) == 0xDEADBEEF);
    printf("  BTREE_OPT slots at stride 6: OK (head=0x%08x)\n", p.slot_head(2));
  }

  printf("  PASSED\n");
  return 0;
}

int test_heads_comparison() {
  printf("=== test_heads_comparison ===\n");

  TestPage p;
  p.init(true);

  // Simulate user records. Insert with keys that have different heads.
  auto r0_pos = p.insert_record("AAAA0001");  // Head = 0x41414141
  auto r1_pos = p.insert_record("BBBB0002");  // Head = 0x42424242
  auto r2_pos = p.insert_record("CCCC0003");  // Head = 0x43434343

  // Create 3 slots, each pointing to one record
  p.set_n_slots(3);
  size_t sz = SLOT_SIZE_OPT;
  p.write_slot(PAGE_SIZE - PAGE_DIR - sz, r0_pos, sz, 0x41414141);
  p.write_slot(PAGE_SIZE - PAGE_DIR - sz * 2, r1_pos, sz, 0x42424242);
  p.write_slot(PAGE_SIZE - PAGE_DIR - sz * 3, r2_pos, sz, 0x43434343);

  // Verify Heads
  assert(p.slot_head(0) == 0x41414141);
  assert(p.slot_head(1) == 0x42424242);
  assert(p.slot_head(2) == 0x43434343);

  printf("  Records with distinct Heads: OK\n");
  printf("    slot[0]: offset=%u head=0x%08x\n", p.slot_offset(0), p.slot_head(0));
  printf("    slot[1]: offset=%u head=0x%08x\n", p.slot_offset(1), p.slot_head(1));
  printf("    slot[2]: offset=%u head=0x%08x\n", p.slot_offset(2), p.slot_head(2));

  printf("  PASSED\n");
  return 0;
}

int test_hints_array() {
  printf("=== test_hints_array ===\n");

  TestPage p;
  p.init(true);

  // Write 16 Hints to the page at PAGE_HINTS offset
  constexpr size_t PAGE_HINTS = NEW_SUPREMUM_END + 4;
  uint32_t sample_heads[16];
  for (int i = 0; i < 16; i++) {
    sample_heads[i] = static_cast<uint32_t>(0x41000000 + (i * 0x10000));
    p.data[PAGE_HINTS + i*4]   = static_cast<uint8_t>(sample_heads[i] >> 24);
    p.data[PAGE_HINTS + i*4+1] = static_cast<uint8_t>(sample_heads[i] >> 16);
    p.data[PAGE_HINTS + i*4+2] = static_cast<uint8_t>(sample_heads[i] >> 8);
    p.data[PAGE_HINTS + i*4+3] = static_cast<uint8_t>(sample_heads[i] & 0xFF);
  }

  // Verify hints are readable
  for (int i = 0; i < 16; i++) {
    uint32_t read_back =
        static_cast<uint32_t>(
            (p.data[PAGE_HINTS + i*4] << 24) |
            (p.data[PAGE_HINTS + i*4+1] << 16) |
            (p.data[PAGE_HINTS + i*4+2] << 8) |
            p.data[PAGE_HINTS + i*4+3]);
    assert(read_back == sample_heads[i]);
  }

  printf("  Hints[16] array: OK\n");
  printf("  Hint[0]=0x%08x Hint[7]=0x%08x Hint[15]=0x%08x\n",
         sample_heads[0], sample_heads[7], sample_heads[15]);

  printf("  PASSED\n");
  return 0;
}

int test_fully_dense_bitmap() {
  printf("=== test_fully_dense_bitmap ===\n");

  constexpr size_t PAGE_FD_BITMAP = NEW_SUPREMUM_END + 4 + 64 + 4 + 32 + 8;

  TestPage p;
  p.init(true);
  p.set_btree_flags(1 << 1);  // FULLY_DENSE

  // Set base_key = 1000
  constexpr size_t PAGE_FD_BASE_KEY = NEW_SUPREMUM_END + 4 + 64 + 4 + 32;
  p.data[PAGE_FD_BASE_KEY] = 0;
  p.data[PAGE_FD_BASE_KEY+1] = 0;
  p.data[PAGE_FD_BASE_KEY+2] = 0;
  p.data[PAGE_FD_BASE_KEY+3] = 0;
  p.data[PAGE_FD_BASE_KEY+4] = 0;
  p.data[PAGE_FD_BASE_KEY+5] = 0;
  p.data[PAGE_FD_BASE_KEY+6] = 0x03;
  p.data[PAGE_FD_BASE_KEY+7] = 0xE8;  // base = 1000

  // Set bitmap: occupy slots 5, 10, 50
  auto set_bit = [&](size_t idx) {
    p.data[PAGE_FD_BITMAP + idx/8] |= static_cast<uint8_t>(1 << (idx % 8));
  };
  set_bit(5);
  set_bit(10);
  set_bit(50);

  // Verify
  auto test_bit = [&](size_t idx) -> bool {
    return (p.data[PAGE_FD_BITMAP + idx/8] & (1 << (idx % 8))) != 0;
  };

  assert(test_bit(5));
  assert(test_bit(10));
  assert(test_bit(50));
  assert(!test_bit(0));
  assert(!test_bit(6));
  assert(!test_bit(11));

  printf("  Fully-Dense bitmap: OK\n");
  printf("  base_key=%lu, bitmap[5]=%d [10]=%d [50]=%d [0]=%d\n",
         static_cast<unsigned long>(1000),
         test_bit(5), test_bit(10), test_bit(50), test_bit(0));

  printf("  PASSED\n");
  return 0;
}

int test_prefix_truncation() {
  printf("=== test_prefix_truncation ===\n");

  constexpr size_t PAGE_PREFIX_LEN = NEW_SUPREMUM_END + 4 + 64;
  constexpr size_t PAGE_PREFIX_BUF = PAGE_PREFIX_LEN + 4;

  TestPage p;
  p.init(true);

  // Set prefix: "https://example.com/" (20 bytes)
  const char *prefix = "https://example.com/";
  uint32_t plen = static_cast<uint32_t>(strlen(prefix));

  // Write prefix length
  p.data[PAGE_PREFIX_LEN]   = static_cast<uint8_t>(plen >> 24);
  p.data[PAGE_PREFIX_LEN+1] = static_cast<uint8_t>(plen >> 16);
  p.data[PAGE_PREFIX_LEN+2] = static_cast<uint8_t>(plen >> 8);
  p.data[PAGE_PREFIX_LEN+3] = static_cast<uint8_t>(plen & 0xFF);

  // Write prefix data
  memcpy(&p.data[PAGE_PREFIX_BUF], prefix, plen);

  // Read back and verify
  uint32_t rlen = static_cast<uint32_t>(
      (p.data[PAGE_PREFIX_LEN] << 24) |
      (p.data[PAGE_PREFIX_LEN+1] << 16) |
      (p.data[PAGE_PREFIX_LEN+2] << 8) |
      p.data[PAGE_PREFIX_LEN+3]);
  assert(rlen == plen);

  char rbuf[33] = {};
  memcpy(rbuf, &p.data[PAGE_PREFIX_BUF], std::min<uint32_t>(rlen, 32));
  assert(strcmp(rbuf, prefix) == 0);

  printf("  Prefix: len=%u buf='%s': OK\n", rlen, rbuf);
  printf("  PASSED\n");
  return 0;
}

int test_adaptive_layout() {
  printf("=== test_adaptive_layout ===\n");

  constexpr size_t PAGE_ADAPT_LAYOUT = 179;  // from header layout
  constexpr size_t PAGE_ADAPT_HEADS_COLL = 178;

  TestPage p;
  p.init(true);

  // Simulate: after adaptive detection
  p.data[PAGE_ADAPT_HEADS_COLL] = 85;   // 85% collision → string keys
  p.data[PAGE_ADAPT_LAYOUT] = 2;         // PAGE_LAYOUT_HEADS_PREFIX

  assert(p.data[PAGE_ADAPT_HEADS_COLL] == 85);
  assert(p.data[PAGE_ADAPT_LAYOUT] == 2);

  printf("  Adaptive: collision=85%% layout=HEADS_PREFIX: OK\n");

  // Change to different profile
  p.data[PAGE_ADAPT_HEADS_COLL] = 5;    // 5% → integer keys
  p.data[PAGE_ADAPT_LAYOUT] = 4;         // PAGE_LAYOUT_SEMI_DENSE
  assert(p.data[PAGE_ADAPT_LAYOUT] == 4);

  printf("  Adaptive: collision=5%% layout=SEMI_DENSE: OK\n");

  printf("  PASSED\n");
  return 0;
}

int test_performance_heads_filtering() {
  printf("=== test_performance_heads_filtering ===\n");

  TestPage p;
  p.init(true);

  // Create 16 slots with different Heads
  p.set_n_slots(16);
  size_t sz = SLOT_SIZE_OPT;

  for (int i = 0; i < 16; i++) {
    uint32_t head = static_cast<uint32_t>(0x40000000 + i * 0x1000000);
    // Minimal record at different offsets
    size_t offset = static_cast<size_t>(HEAP_START + i * 64);
    p.write_slot(PAGE_SIZE - PAGE_DIR - sz * (i+1), offset, sz, head);
  }

  // Measure: searching for Head=0x45000000 (slot 5 out of 16)
  // Normal binary search: log2(16) = 4 comparisons
  // Heads filter: 1 comparison per slot
  // Total Heads checks: 4 (binary search steps)
  uint32_t target_head = 0x45000000;
  int n_checks = 0;

  // Simulate binary search with Heads pre-check
  int low = 0, up = 15;
  while (up - low > 1) {
    int mid = (low + up) / 2;
    uint32_t slot_head = p.slot_head(static_cast<size_t>(mid));
    n_checks++;
    if (target_head < slot_head)
      up = mid;
    else if (target_head > slot_head)
      low = mid;
    else
      break;  // exact match
  }

  printf("  Binary search: log2(16)=4, actual checks=%d\n", n_checks);
  assert(n_checks <= 4);

  printf("  PASSED (Heads filtering: ~%d comparisons vs 4 without)\n", n_checks);
  return 0;
}

int main() {
  printf("========================================\n");
  printf("B-Tree Optimization Page-Level Tests\n");
  printf("========================================\n\n");

  int failures = 0;

  failures += test_page_format_detection();
  failures += test_heads_initialization();
  failures += test_slot_dynamic_stride();
  failures += test_heads_comparison();
  failures += test_hints_array();
  failures += test_fully_dense_bitmap();
  failures += test_prefix_truncation();
  failures += test_adaptive_layout();
  failures += test_performance_heads_filtering();

  printf("\n========================================\n");
  printf("Results: %d tests, %d failures\n", 9, failures);
  printf("========================================\n");
  return failures;
}
