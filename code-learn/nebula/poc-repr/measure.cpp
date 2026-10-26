// Byte and heap model of NebulaGraph v3.8.0 Value / DataSet / TBinaryProtocol.
//
// This is not linked against nebula. Layout follows:
//   src/common/datatypes/Value.h          sizeof(Value) == 16, INT/FLOAT inline
//   src/common/datatypes/List.h           vector<Value>
//   src/common/datatypes/DataSet.h        using Row = List
//   src/common/datatypes/ValueOps-inl.h   Cpp2Ops<Value>::write
//   src/common/datatypes/ListOps-inl.h    Cpp2Ops<List>::write  (NList, field 1)
//   src/common/datatypes/DataSetOps-inl.h
//   src/interface/common.thrift           Value / NList / Row / DataSet
//   src/interface/storage.thrift          ResponseCommon, GetNeighbors, GetDstBySrc, LookupIndex
//   src/common/thrift/ThriftClientManager-inl.h   T_BINARY_PROTOCOL
//
// TBinaryProtocol field widths (struct name is not written):
//   struct begin/end 0, field begin 1+2, field end 0, field stop 1,
//   i64/double 8, bool 1, i32 4, binary 4+n, list begin 1+4.
// Row is `using Row = List`, so a DataSet row is encoded by Cpp2Ops<List>
// (struct NList, one list<Value> field). Binary protocol does not write the
// struct name, so NList and thrift Row are the same number of bytes.
//
// Heap numbers use this process's operator new and malloc_usable_size (glibc).
// The v3.8.0 binary in doc 12 was linked with jemalloc. sizeof and logical
// capacity are allocator-independent; usable sizes are glibc size classes.
//
// Build: g++ -std=c++17 -O2 -o measure measure.cpp && ./measure beauty_item_names.txt

#include <malloc.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#include <deque>
#include <fstream>
#include <functional>

namespace heap {
std::size_t live = 0;
std::size_t peak = 0;
bool on = false;

void account_alloc(void* p) {
  if (!on || p == nullptr) {
    return;
  }
  live += ::malloc_usable_size(p);
  peak = std::max(peak, live);
}

void account_free(void* p) {
  if (!on || p == nullptr) {
    return;
  }
  auto n = ::malloc_usable_size(p);
  if (n > live) {
    live = 0;
  } else {
    live -= n;
  }
}
}  // namespace heap

void* operator new(std::size_t n) {
  void* p = std::malloc(n);
  if (!p) {
    throw std::bad_alloc();
  }
  heap::account_alloc(p);
  return p;
}
void* operator new(std::size_t n, const std::nothrow_t&) noexcept {
  void* p = std::malloc(n);
  heap::account_alloc(p);
  return p;
}
void* operator new[](std::size_t n) {
  return ::operator new(n);
}
void* operator new[](std::size_t n, const std::nothrow_t&) noexcept {
  return ::operator new(n, std::nothrow);
}
void operator delete(void* p) noexcept {
  heap::account_free(p);
  std::free(p);
}
void operator delete(void* p, std::size_t) noexcept {
  ::operator delete(p);
}
void operator delete(void* p, const std::nothrow_t&) noexcept {
  ::operator delete(p);
}
void operator delete[](void* p) noexcept {
  ::operator delete(p);
}
void operator delete[](void* p, std::size_t) noexcept {
  ::operator delete(p);
}
void operator delete[](void* p, const std::nothrow_t&) noexcept {
  ::operator delete(p);
}

struct Val {
  std::uint64_t type;
  std::uint64_t payload;
};
static_assert(sizeof(Val) == 16, "mirror of Value must be 16 bytes");

enum Type : std::uint64_t {
  kEmpty = 1,
  kInt = 1ull << 2,
  kFloat = 1ull << 3,
  kString = 1ull << 4,
  kList = 1ull << 11,
};

struct List {
  std::vector<Val> values;
};

Val make_int(std::int64_t v) {
  return Val{kInt, static_cast<std::uint64_t>(v)};
}
Val make_empty() {
  return Val{kEmpty, 0};
}
Val make_float(double d) {
  Val v;
  v.type = kFloat;
  std::memcpy(&v.payload, &d, sizeof(d));
  return v;
}
Val make_string(const std::string& s) {
  auto* heap = new std::string(s);
  return Val{kString, reinterpret_cast<std::uint64_t>(heap)};
}
Val make_list(List* list) {
  return Val{kList, reinterpret_cast<std::uint64_t>(list)};
}

void destroy_val(Val& v) {
  if (v.type == kString) {
    delete reinterpret_cast<std::string*>(v.payload);
  } else if (v.type == kList) {
    auto* list = reinterpret_cast<List*>(v.payload);
    for (auto& c : list->values) {
      destroy_val(c);
    }
    delete list;
  }
  v.type = kEmpty;
  v.payload = 0;
}

struct Row {
  std::vector<Val> values;
  ~Row() {
    for (auto& v : values) {
      destroy_val(v);
    }
  }
  Row() = default;
  Row(Row&& o) noexcept : values(std::move(o.values)) {}
  Row& operator=(Row&& o) noexcept {
    if (this != &o) {
      for (auto& v : values) {
        destroy_val(v);
      }
      values = std::move(o.values);
    }
    return *this;
  }
  Row(const Row&) = delete;
  Row& operator=(const Row&) = delete;
};

struct Scope {
  std::size_t begin;
  std::size_t begin_peak;
  Scope() {
    heap::on = true;
    begin = heap::live;
    begin_peak = heap::peak;
    heap::peak = heap::live;
  }
  std::size_t live() const {
    return heap::live - begin;
  }
  std::size_t peak() const {
    return heap::peak - begin;
  }
  ~Scope() {
    heap::on = false;
  }
};

// --- TBinaryProtocol byte counter matching Cpp2Ops::write ---

constexpr std::uint32_t kFieldBegin = 3;
constexpr std::uint32_t kFieldStop = 1;
constexpr std::uint32_t kListBegin = 5;

enum class CellKind { Int, Double, Empty, String, List };

struct Cell {
  CellKind kind;
  std::uint32_t n = 0;  // string length, unused otherwise
  std::vector<Cell> elems;
};

std::uint32_t value_bytes(const Cell& c);

std::uint32_t nlist_bytes(const std::vector<Cell>& elems) {
  std::uint32_t n = kFieldBegin + kListBegin + kFieldStop;
  for (const auto& e : elems) {
    n += value_bytes(e);
  }
  return n;
}

std::uint32_t value_bytes(const Cell& c) {
  switch (c.kind) {
    case CellKind::Empty:
      return kFieldStop;
    case CellKind::Int:
    case CellKind::Double:
      return kFieldBegin + 8 + kFieldStop;
    case CellKind::String:
      return kFieldBegin + 4 + c.n + kFieldStop;
    case CellKind::List:
      return kFieldBegin + nlist_bytes(c.elems) + kFieldStop;
  }
  return 0;
}

std::uint32_t row_bytes(const std::vector<Cell>& cells) {
  return nlist_bytes(cells);
}

std::uint32_t dataset_bytes(const std::vector<std::string>& cols,
                            const std::vector<std::vector<Cell>>& rows) {
  std::uint32_t n = 0;
  n += kFieldBegin + kListBegin;
  for (const auto& col : cols) {
    n += 4 + static_cast<std::uint32_t>(col.size());
  }
  n += kFieldBegin + kListBegin;
  for (const auto& row : rows) {
    n += row_bytes(row);
  }
  n += kFieldStop;
  return n;
}

std::uint32_t response_common_bytes() {
  // field 1 empty list<PartitionResult>, field 2 i64, stop. No latency_detail.
  return kFieldBegin + kListBegin + kFieldBegin + 8 + kFieldStop;
}

std::uint32_t wrap_response(std::uint32_t dataset, bool with_stat) {
  // field 1 ResponseCommon + field 2 DataSet [+ field 3 stat DataSet] + stop
  std::uint32_t n = kFieldBegin + response_common_bytes();
  n += kFieldBegin + dataset;
  if (with_stat) {
    n += kFieldBegin + dataset_bytes({}, {});
  }
  n += kFieldStop;
  return n;
}

std::uint32_t execution_response_bytes(std::uint32_t dataset) {
  // error_code i32 + latency i64 + data DataSet + stop. space_name omitted.
  return kFieldBegin + 4 + kFieldBegin + 8 + kFieldBegin + dataset + kFieldStop;
}

Cell CInt() {
  return Cell{CellKind::Int, 0, {}};
}
Cell CDouble() {
  return Cell{CellKind::Double, 0, {}};
}
Cell CEmpty() {
  return Cell{CellKind::Empty, 0, {}};
}
Cell CStr(std::uint32_t n) {
  return Cell{CellKind::String, n, {}};
}
Cell CList(std::vector<Cell> elems) {
  return Cell{CellKind::List, 0, std::move(elems)};
}

void expect(const char* name, std::uint32_t got, std::uint32_t want) {
  if (got != want) {
    std::cerr << "FAIL " << name << " got " << got << " want " << want << "\n";
    std::exit(1);
  }
  std::cout << "check " << name << " " << got << "\n";
}

struct HeapReport {
  std::size_t live = 0;
  std::size_t peak = 0;
  std::size_t rows_size = 0;
  std::size_t rows_cap = 0;
};

template <class F>
HeapReport measure(F&& fn) {
  Scope s;
  auto extra = fn();
  HeapReport r;
  r.live = s.live();
  r.peak = s.peak();
  r.rows_size = extra.first;
  r.rows_cap = extra.second;
  return r;
}

void print_heap(const char* name, const HeapReport& r) {
  std::cout << "heap " << name << " live " << r.live << " peak " << r.peak << " rows " << r.rows_size
            << " cap " << r.rows_cap << "\n";
}

std::vector<std::string> load_names(const std::string& path) {
  std::ifstream in(path);
  if (!in) {
    throw std::runtime_error("cannot open " + path);
  }
  std::vector<std::string> names;
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty()) {
      names.push_back(line);
    }
  }
  return names;
}

// Grow a row the way GetNeighborsNode does: two emplaces, then resize.
Row gn_vertex_row(std::int64_t vid, List* edges_or_null) {
  Row row;
  row.values.emplace_back(make_int(vid));
  row.values.emplace_back(make_empty());
  row.values.resize(4, make_empty());
  if (edges_or_null != nullptr) {
    row.values[2] = make_list(edges_or_null);
  }
  return row;
}

struct NeighborBuild {
  std::vector<Row> rows;
  std::size_t outer_spare_slots = 0;
  std::size_t inner_lists = 0;
};

NeighborBuild build_neighbors(const std::vector<int>& fanout, bool with_amount) {
  NeighborBuild out;
  for (std::size_t i = 0; i < fanout.size(); ++i) {
    List* edges = nullptr;
    int n = fanout[i];
    if (n > 0) {
      edges = new List();
      // GetNeighborsNode::iterateEdges emplaces without reserve.
      for (int e = 0; e < n; ++e) {
        auto* inner = new List();
        if (with_amount) {
          inner->values.reserve(3);
          inner->values.push_back(make_int(1));
          inner->values.push_back(make_float(1.0));
          inner->values.push_back(make_int(1753660801));
        } else {
          inner->values.reserve(2);
          inner->values.push_back(make_int(1));
          inner->values.push_back(make_int(1753660801));
        }
        edges->values.emplace_back(make_list(inner));
        ++out.inner_lists;
      }
      out.outer_spare_slots += edges->values.capacity() - edges->values.size();
    }
    out.rows.push_back(gn_vertex_row(100000000 + static_cast<std::int64_t>(i), edges));
  }
  return out;
}

std::vector<int> even_fanout(int vertices, int edges) {
  std::vector<int> n(vertices, edges / vertices);
  for (int i = 0; i < edges % vertices; ++i) {
    n[i] += 1;
  }
  return n;
}

std::vector<int> one_vertex_fanout(int vertices, int edges) {
  std::vector<int> n(vertices, 0);
  n[0] = edges;
  return n;
}

void section_sizes() {
  std::cout << "sizeof Val " << sizeof(Val) << "\n";
  std::cout << "sizeof vector<Val> " << sizeof(std::vector<Val>) << "\n";
  std::cout << "sizeof string " << sizeof(std::string) << "\n";
  std::cout << "sizeof unique_ptr<string> " << sizeof(std::unique_ptr<std::string>) << "\n";
  std::cout << "sizeof unordered_set<int> " << sizeof(std::unordered_set<int>) << "\n";
  std::cout << "sizeof unordered_map<int,int> " << sizeof(std::unordered_map<int, int>) << "\n";
  std::cout << "sizeof deque<Row> " << sizeof(std::deque<Row>) << "\n";
  std::string sso("beauty");
  std::string long_s(32, 'x');
  std::cout << "string capacity beauty " << sso.capacity() << " long32 " << long_s.capacity() << "\n";
}

struct HashVal {
  std::size_t operator()(const Val& v) const {
    return std::hash<std::uint64_t>{}(v.payload);
  }
};
struct EqVal {
  bool operator()(const Val& a, const Val& b) const {
    return a.type == b.type && a.payload == b.payload;
  }
};

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: measure beauty_item_names.txt\n";
    return 2;
  }
  const auto names = load_names(argv[1]);
  if (names.size() != 382) {
    std::cerr << "expected 382 beauty names, got " << names.size() << "\n";
    return 2;
  }
  std::uint32_t name_bytes = 0;
  for (const auto& n : names) {
    name_bytes += static_cast<std::uint32_t>(n.size());
  }
  std::cout << "beauty_names " << names.size() << " chars " << name_bytes << "\n";

  expect("empty_value", value_bytes(CEmpty()), 1);
  expect("int_value", value_bytes(CInt()), 12);
  expect("double_value", value_bytes(CDouble()), 12);
  expect("string_beauty", value_bytes(CStr(6)), 14);
  expect("empty_dataset", dataset_bytes({}, {}), 17);
  expect("response_common", response_common_bytes(), 20);
  expect("list_two_ints", value_bytes(CList({CInt(), CInt()})), 37);

  section_sizes();

  constexpr int kEdges = 40415;
  constexpr int kItems = 382;
  constexpr int kUsers = 4000;
  constexpr int kTop = 100;

  // --- tag index scan: 382 rows, columns _vid _tag name type ---
  {
    Scope s;
    std::vector<Row> rows;
    for (int i = 0; i < kItems; ++i) {
      Row row;
      row.values.emplace_back(make_int(100000000 + i));
      row.values.emplace_back(make_int(1));
      row.values.emplace_back(make_string(names[i]));
      row.values.emplace_back(make_string("beauty"));
      rows.emplace_back(std::move(row));
    }
    print_heap("tag_scan_grown", HeapReport{s.live(), s.peak(), rows.size(), rows.capacity()});
  }
  {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(kItems);
    for (int i = 0; i < kItems; ++i) {
      Row row;
      row.values.reserve(4);
      row.values.push_back(make_int(100000000 + i));
      row.values.push_back(make_int(1));
      row.values.push_back(make_string(names[i]));
      row.values.push_back(make_string("beauty"));
      rows.emplace_back(std::move(row));
    }
    print_heap("tag_scan_reserved", HeapReport{s.live(), s.peak(), rows.size(), rows.capacity()});
  }

  auto thrift_tag = [&] {
    std::vector<std::vector<Cell>> rows;
    rows.reserve(names.size());
    for (const auto& name : names) {
      rows.push_back({CInt(), CInt(), CStr(static_cast<std::uint32_t>(name.size())), CStr(6)});
    }
    auto ds = dataset_bytes({"item._vid", "item._tag", "item.name", "item.type"}, rows);
    std::cout << "thrift tag_dataset " << ds << "\n";
    std::cout << "thrift tag_lookup_resp " << wrap_response(ds, true) << "\n";
  };
  thrift_tag();

  // project id: 382 x 1 int, grown
  {
    Scope s;
    std::vector<Row> rows;
    for (int i = 0; i < kItems; ++i) {
      Row row;
      row.values.emplace_back(make_int(100000000 + i));
      rows.emplace_back(std::move(row));
    }
    print_heap("project_id_382", HeapReport{s.live(), s.peak(), rows.size(), rows.capacity()});
  }

  auto measure_gn = [&](bool amount, const std::vector<int>& fanout, const char* name) {
    Scope s;
    auto built = build_neighbors(fanout, amount);
    HeapReport r;
    r.live = s.live();
    r.peak = s.peak();
    r.rows_size = built.rows.size();
    r.rows_cap = built.rows.capacity();
    std::cout << "gn_meta " << name << " spare_outer " << built.outer_spare_slots << "\n";
    print_heap(name, r);
    // built destroyed while scope still counting, that's ok after the print
  };
  measure_gn(false, even_fanout(kItems, kEdges), "gn_users_even");
  measure_gn(false, one_vertex_fanout(kItems, kEdges), "gn_users_one");
  measure_gn(true, even_fanout(kItems, kEdges), "gn_sales_even");
  measure_gn(true, one_vertex_fanout(kItems, kEdges), "gn_sales_one");

  auto thrift_gn = [&](bool amount, const std::vector<int>& fanout, const char* name) {
    std::string edge_col = amount ? "_edge:-buy:_dst:amount:ts" : "_edge:-buy:_dst:ts";
    std::vector<std::string> cols{"_vid", "_stats", edge_col, "_expr"};
    std::vector<std::vector<Cell>> rows;
    rows.reserve(fanout.size());
    std::uint64_t edge_payload = 0;
    for (int n : fanout) {
      std::vector<Cell> row{CInt(), CEmpty(), CEmpty(), CEmpty()};
      if (n > 0) {
        std::vector<Cell> edges;
        edges.reserve(n);
        for (int i = 0; i < n; ++i) {
          if (amount) {
            edges.push_back(CList({CInt(), CDouble(), CInt()}));
          } else {
            edges.push_back(CList({CInt(), CInt()}));
          }
        }
        edge_payload += value_bytes(CList(edges));
        row[2] = CList(std::move(edges));
      }
      rows.push_back(std::move(row));
    }
    auto ds = dataset_bytes(cols, rows);
    std::cout << "thrift " << name << "_dataset " << ds << " edge_cells " << edge_payload << "\n";
    std::cout << "thrift " << name << "_resp " << wrap_response(ds, false) << "\n";
  };
  thrift_gn(false, even_fanout(kItems, kEdges), "gn_users_even");
  thrift_gn(false, one_vertex_fanout(kItems, kEdges), "gn_users_one");
  thrift_gn(true, even_fanout(kItems, kEdges), "gn_sales_even");
  thrift_gn(true, one_vertex_fanout(kItems, kEdges), "gn_sales_one");

  // Flat graphd datasets. Grown by emplace, no reserve, matching Project/ExpandAll/Join.
  auto flat = [&](int nrows, const std::vector<CellKind>& kinds, bool reserve_rows, const char* name) {
    Scope s;
    std::vector<Row> rows;
    if (reserve_rows) {
      rows.reserve(static_cast<std::size_t>(nrows));
    }
    for (int i = 0; i < nrows; ++i) {
      Row row;
      for (auto k : kinds) {
        if (k == CellKind::Int) {
          row.values.emplace_back(make_int(i));
        } else if (k == CellKind::Double) {
          row.values.emplace_back(make_float(1.0));
        } else {
          throw std::runtime_error("flat kind");
        }
      }
      rows.emplace_back(std::move(row));
    }
    std::size_t cell_cap = rows.empty() ? 0 : rows.front().values.capacity();
    std::cout << "flat_cell_cap " << name << " " << cell_cap << "\n";
    HeapReport r{s.live(), s.peak(), rows.size(), rows.capacity()};
    print_heap(name, r);
    std::vector<std::vector<Cell>> cells;
    cells.reserve(nrows);
    std::vector<Cell> proto;
    for (auto k : kinds) {
      proto.push_back(k == CellKind::Int ? CInt() : CDouble());
    }
    for (int i = 0; i < nrows; ++i) {
      cells.push_back(proto);
    }
    std::vector<std::string> cols;
    for (std::size_t i = 0; i < kinds.size(); ++i) {
      cols.push_back("c" + std::to_string(i));
    }
    // column name bytes are not the real names; print payload with caller names separately
    (void)cells;
  };

  // ExpandAll result_ grows by emplace (no reserve). Project and Join reserve the row vector.
  // Join::newRow reserves the cell vector to left+right width. Project does not reserve cells.
  flat(40415, {CellKind::Int, CellKind::Int, CellKind::Int}, false, "flat_expandall_users");
  flat(40415, {CellKind::Int, CellKind::Int, CellKind::Int, CellKind::Int}, true, "flat_join_users");
  flat(40415, {CellKind::Int}, true, "flat_project_user");
  flat(40415,
       {CellKind::Int, CellKind::Int, CellKind::Int, CellKind::Double},
       false,
       "flat_expandall_sales");
  flat(40415,
       {CellKind::Int, CellKind::Int, CellKind::Int, CellKind::Int, CellKind::Double},
       true,
       "flat_join_sales_grown_cells");
  {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.reserve(5);
      row.values.push_back(make_int(i));
      row.values.push_back(make_int(i));
      row.values.push_back(make_int(i));
      row.values.push_back(make_int(i));
      row.values.push_back(make_float(1.0));
      rows.emplace_back(std::move(row));
    }
    std::cout << "flat_cell_cap flat_join_sales_reserved_cells " << rows.front().values.capacity() << "\n";
    print_heap("flat_join_sales_reserved_cells",
               HeapReport{s.live(), s.peak(), rows.size(), rows.capacity()});
  }
  flat(40415, {CellKind::Int, CellKind::Double}, true, "flat_project_sales");
  flat(4000, {CellKind::Int, CellKind::Double}, true, "flat_agg_out");
  flat(100, {CellKind::Int, CellKind::Double}, true, "flat_topn_kept");

  // Dedup does not shrink capacity. Build 40415 then pop down to 4000.
  {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.emplace_back(make_int(i % kUsers));
      rows.emplace_back(std::move(row));
    }
    auto cap_before = rows.capacity();
    auto live_before = s.live();
    std::unordered_set<const void*> seen;
    seen.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      seen.insert(&rows[static_cast<std::size_t>(i)]);
    }
    auto live_with_set = s.live();
    std::cout << "dedup cap_before " << cap_before << " cap_after_build " << rows.capacity()
              << " live_rows " << live_before << " live_rows_plus_std_set " << live_with_set
              << " set_buckets " << seen.bucket_count() << "\n";
  }
  {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.emplace_back(make_int(i % kUsers));
      rows.emplace_back(std::move(row));
    }
    while (rows.size() > static_cast<std::size_t>(kUsers)) {
      rows.pop_back();
    }
    std::cout << "dedup_after_pop live " << s.live() << " size " << rows.size() << " cap " << rows.capacity()
              << "\n";
  }

  // Aggregate map: 4000 keys, each AggData owns an empty unordered_set (Set).
  {
    struct SetObj {
      std::unordered_set<Val, HashVal, EqVal> values;
    };
    struct Agg {
      Val cnt, sum, avg, deviation, result;
      SetObj* uniques;
      Agg() : cnt(make_int(0)), sum(make_float(0)), avg(make_float(0)), deviation(make_float(0)), result(make_int(0)), uniques(new SetObj()) {}
      Agg(Agg&& o) noexcept : cnt(o.cnt), sum(o.sum), avg(o.avg), deviation(o.deviation), result(o.result), uniques(o.uniques) {
        o.uniques = nullptr;
      }
      ~Agg() {
        delete uniques;
      }
    };
    struct Key {
      std::vector<Val> values;
      bool operator==(const Key& o) const {
        return values.size() == o.values.size() && values[0].payload == o.values[0].payload;
      }
    };
    struct HashKey {
      std::size_t operator()(const Key& k) const {
        return std::hash<std::uint64_t>{}(k.values[0].payload);
      }
    };
    Scope s;
    std::unordered_map<Key, std::vector<Agg>, HashKey> table;
    table.reserve(kUsers);
    for (int i = 0; i < kUsers; ++i) {
      Key key;
      key.values.emplace_back(make_int(i + 1));
      std::vector<Agg> cols;
      cols.emplace_back();
      cols.emplace_back();
      table.emplace(std::move(key), std::move(cols));
    }
    std::cout << "agg_map live " << s.live() << " peak " << s.peak() << " groups " << table.size()
              << " bucket_count " << table.bucket_count() << "\n";
  }
  // Same table, but Agg does not allocate the empty Set. SUM / COUNT never touch it;
  // only AggregateExpression::distinct_ reads uniques().
  {
    struct Agg {
      Val cnt, sum, avg, deviation, result;
      void* uniques;
      Agg()
          : cnt(make_int(0)),
            sum(make_float(0)),
            avg(make_float(0)),
            deviation(make_float(0)),
            result(make_int(0)),
            uniques(nullptr) {}
    };
    struct Key {
      std::vector<Val> values;
      bool operator==(const Key& o) const {
        return values.size() == o.values.size() && values[0].payload == o.values[0].payload;
      }
    };
    struct HashKey {
      std::size_t operator()(const Key& k) const {
        return std::hash<std::uint64_t>{}(k.values[0].payload);
      }
    };
    Scope s;
    std::unordered_map<Key, std::vector<Agg>, HashKey> table;
    table.reserve(kUsers);
    for (int i = 0; i < kUsers; ++i) {
      Key key;
      key.values.emplace_back(make_int(i + 1));
      std::vector<Agg> cols;
      cols.emplace_back();
      cols.emplace_back();
      table.emplace(std::move(key), std::move(cols));
    }
    std::cout << "p0_agg_map_no_set live " << s.live() << " peak " << s.peak()
              << " groups " << table.size() << " bucket_count " << table.bucket_count() << "\n";
  }

  // Join hash on 382 int keys, one Row* each.
  {
    Scope s;
    std::unordered_map<Val, std::vector<const void*>, HashVal, EqVal> table;
    table.reserve(kItems);
    std::vector<Row> left;
    left.reserve(kItems);
    for (int i = 0; i < kItems; ++i) {
      Row row;
      row.values.emplace_back(make_int(i));
      left.emplace_back(std::move(row));
      table[left.back().values[0]].push_back(&left.back());
    }
    std::cout << "join_hash live " << s.live() << " buckets " << table.bucket_count() << "\n";
  }

  // VidHashSet stand-in: unordered_set of 382 inline ints stored as Val.
  {
    Scope s;
    std::unordered_set<Val, HashVal, EqVal> set;
    set.reserve(kItems);
    for (int i = 0; i < kItems; ++i) {
      set.insert(make_int(i));
    }
    std::cout << "vid_hash live " << s.live() << " buckets " << set.bucket_count() << "\n";
  }

  // q_model: 7 columns, projection reserves the row, result vector grows by emplace.
  // Also a deque of the same rows (per-part buffer) coexisting with the vector.
  {
    Scope s;
    std::deque<Row> parts;
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.reserve(7);
      row.values.push_back(make_int(i % kUsers + 1));
      row.values.push_back(make_int(100000000 + (i % kItems)));
      row.values.push_back(make_int(0));
      row.values.push_back(make_int(-18));
      row.values.push_back(make_float(1.0));
      row.values.push_back(make_string("beauty"));
      row.values.push_back(make_int(1753660801));
      parts.emplace_back(std::move(row));
    }
    auto after_deque = s.live();
    std::vector<Row> result;
    for (auto& row : parts) {
      result.emplace_back(std::move(row));
    }
    auto after_both = s.live();
    parts.clear();
    auto after_clear = s.live();
    std::cout << "q_model deque " << after_deque << " deque_plus_vector " << after_both
              << " vector_only " << after_clear << " result_size " << result.size() << " result_cap "
              << result.capacity() << " peak " << s.peak() << "\n";
  }
  // graphd copy: another vector, rows reserved to 7, vector itself grown by insert-like emplace
  {
    Scope s;
    std::vector<Row> rows;
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.reserve(7);
      row.values.push_back(make_int(1));
      row.values.push_back(make_int(2));
      row.values.push_back(make_int(0));
      row.values.push_back(make_int(-18));
      row.values.push_back(make_float(1.0));
      row.values.push_back(make_string("beauty"));
      row.values.push_back(make_int(1));
      rows.emplace_back(std::move(row));
    }
    std::cout << "q_model_vector_grown live " << s.live() << " cap " << rows.capacity() << " peak " << s.peak()
              << " cell_cap " << rows.front().values.capacity() << "\n";
  }
  {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.reserve(7);
      row.values.push_back(make_int(1));
      row.values.push_back(make_int(2));
      row.values.push_back(make_int(0));
      row.values.push_back(make_int(-18));
      row.values.push_back(make_float(1.0));
      row.values.push_back(make_string("beauty"));
      row.values.push_back(make_int(1));
      rows.emplace_back(std::move(row));
    }
    std::cout << "q_model_vector_reserved live " << s.live() << " cap " << rows.capacity() << " peak "
              << s.peak() << " cell_cap " << rows.front().values.capacity() << "\n";
  }
  // project down to one int column, coexisting is measured as the sum of the two reports
  {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.emplace_back(make_int(i % kUsers + 1));
      rows.emplace_back(std::move(row));
    }
    std::cout << "q_model_project live " << s.live() << " cap " << rows.capacity() << "\n";
  }

  auto thrift_model = [&] {
    std::vector<std::string> cols{"buy._src", "buy._dst", "buy._rank", "buy._type", "buy.amount", "buy.item_type", "buy.ts"};
    std::vector<Cell> proto{CInt(), CInt(), CInt(), CInt(), CDouble(), CStr(6), CInt()};
    std::vector<std::vector<Cell>> rows(kEdges, proto);
    auto ds = dataset_bytes(cols, rows);
    std::cout << "thrift q_model_dataset " << ds << "\n";
    std::cout << "thrift q_model_lookup_resp " << wrap_response(ds, true) << "\n";
    std::vector<std::string> one{"user"};
    std::vector<std::vector<Cell>> proj(kEdges, std::vector<Cell>{CInt()});
    auto pds = dataset_bytes(one, proj);
    std::cout << "thrift q_model_project_dataset " << pds << "\n";
    std::cout << "thrift q_model_exec_resp " << execution_response_bytes(pds) << "\n";
  };
  thrift_model();

  // GetDstBySrc: 4000 int rows after host dedup, and the pre-dedup vector of 40415 Values.
  {
    Scope s;
    std::vector<Val> flat;
    for (int i = 0; i < kEdges; ++i) {
      flat.emplace_back(make_int(i % kUsers + 1));
    }
    auto pre = s.live();
    std::unordered_set<Val, HashVal, EqVal> uniq;
    uniq.reserve(kEdges);
    for (const auto& v : flat) {
      uniq.insert(v);
    }
    auto with_set = s.live();
    std::vector<Row> out;
    out.reserve(uniq.size());
    for (const auto& v : uniq) {
      Row row;
      row.values.emplace_back(v);
      out.emplace_back(std::move(row));
    }
    std::cout << "getdst pre_vec " << pre << " cap " << flat.capacity() << " plus_std_set " << with_set
              << " plus_out " << s.live() << " unique " << uniq.size() << " out_cap " << out.capacity()
              << "\n";
  }
  {
    std::vector<std::vector<Cell>> rows(kUsers, std::vector<Cell>{CInt()});
    auto ds = dataset_bytes({"_dst"}, rows);
    std::cout << "thrift getdst_dataset " << ds << "\n";
    std::cout << "thrift getdst_resp " << wrap_response(ds, false) << "\n";
    std::vector<std::vector<Cell>> edges(kEdges, std::vector<Cell>{CInt()});
    std::cout << "thrift flat_40415_one_int_dataset " << dataset_bytes({"user"}, edges) << "\n";
    std::cout << "thrift flat_4000_one_int_dataset " << dataset_bytes({"user"}, rows) << "\n";
    std::cout << "thrift exec_4000 " << execution_response_bytes(dataset_bytes({"user"}, rows)) << "\n";
    std::vector<std::vector<Cell>> top(kTop, {CInt(), CDouble()});
    auto tds = dataset_bytes({"uid", "sales"}, top);
    std::cout << "thrift topn_dataset " << tds << "\n";
    std::cout << "thrift topn_exec " << execution_response_bytes(tds) << "\n";
  }

  // Compact representations.
  {
    Scope s;
    std::vector<std::int64_t> vids(kUsers);
    std::vector<std::int64_t> edges(kEdges);
    std::vector<double> amts(kEdges);
    std::cout << "compact int64_4000 " << (s.live()) << " note_next_includes_all\n";
    auto after_users = sizeof(std::vector<std::int64_t>) ; // object is on stack
    (void)after_users;
    std::cout << "compact logical int64*4000 " << (kUsers * sizeof(std::int64_t)) << " int64*40415 "
              << (kEdges * sizeof(std::int64_t)) << " double*40415 " << (kEdges * sizeof(double)) << "\n";
    std::cout << "compact heap_3vecs " << s.live() << "\n";
  }
  // raw list<i64> binary: list begin 5 + 8*n, no Value wrapper
  std::cout << "thrift raw_i64_list_4000 " << (kListBegin + 8 * kUsers) << "\n";
  std::cout << "thrift raw_i64_list_40415 " << (kListBegin + 8 * kEdges) << "\n";

  // Microbench: sum of amount, row-wise Val vs two arrays.
  constexpr int kLoops = 50;
  std::vector<Row> row_amt;
  row_amt.reserve(kEdges);
  for (int i = 0; i < kEdges; ++i) {
    Row row;
    row.values.reserve(2);
    row.values.push_back(make_int(i % kUsers));
    row.values.push_back(make_float(static_cast<double>(i % 500)));
    row_amt.emplace_back(std::move(row));
  }
  std::vector<std::int64_t> col_uid(kEdges);
  std::vector<double> col_amt(kEdges);
  for (int i = 0; i < kEdges; ++i) {
    col_uid[i] = i % kUsers;
    col_amt[i] = static_cast<double>(i % 500);
  }
  auto time_ms = [](auto&& fn) {
    std::vector<double> samples;
    for (int i = 0; i < kLoops; ++i) {
      auto t0 = std::chrono::steady_clock::now();
      auto sink = fn();
      auto t1 = std::chrono::steady_clock::now();
      if (sink == 0) {
        std::cerr << "sink\n";
      }
      samples.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
    }
    std::sort(samples.begin(), samples.end());
    return samples[samples.size() / 2];
  };
  double row_ms = time_ms([&] {
    double sum = 0;
    for (const auto& row : row_amt) {
      double d;
      std::memcpy(&d, &row.values[1].payload, sizeof(d));
      sum += d;
    }
    return sum;
  });
  double col_ms = time_ms([&] {
    double sum = 0;
    for (double d : col_amt) {
      sum += d;
    }
    return sum;
  });
  std::cout << "bench sum_row_ms_median " << row_ms << " sum_col_ms_median " << col_ms << " loops " << kLoops
            << "\n";

  std::vector<std::int64_t> dedup_keys(kEdges);
  std::vector<Val> dedup_vals(kEdges);
  for (int i = 0; i < kEdges; ++i) {
    dedup_keys[static_cast<std::size_t>(i)] = i % kUsers;
    dedup_vals[static_cast<std::size_t>(i)] = make_int(i % kUsers);
  }
  double hash_i64_ms = time_ms([&] {
    std::unordered_set<std::int64_t> seen;
    seen.reserve(static_cast<std::size_t>(kEdges));
    for (auto k : dedup_keys) {
      seen.insert(k);
    }
    return seen.size();
  });
  double hash_val_ms = time_ms([&] {
    std::unordered_set<Val, HashVal, EqVal> seen;
    seen.reserve(static_cast<std::size_t>(kEdges));
    for (const auto& v : dedup_vals) {
      seen.insert(v);
    }
    return seen.size();
  });
  std::cout << "bench dedup_i64_ms_median " << hash_i64_ms << " dedup_val_ms_median " << hash_val_ms
            << " loops " << kLoops << "\n";

  // P0 shapes. getEdge() still needs _src,_dst,_rank,_type. Dropping amount is the
  // visit(EdgeExpression) over-collect. item_type stays while it is a FIXED_STRING
  // filter column; ts is the integer index column the hint already applied.
  flat(40415, {CellKind::Int, CellKind::Int, CellKind::Int}, true, "p0_expandall_users_reserved");
  flat(40415,
       {CellKind::Int, CellKind::Int, CellKind::Int, CellKind::Double},
       true,
       "p0_expandall_sales_reserved");
  {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.emplace_back(make_int(i % kUsers));
      rows.emplace_back(std::move(row));
    }
    while (rows.size() > static_cast<std::size_t>(kUsers)) {
      rows.pop_back();
    }
    auto live_kept = s.live();
    auto cap_kept = rows.capacity();
    rows.shrink_to_fit();
    std::cout << "p0_dedup_shrink before_live " << live_kept << " before_cap " << cap_kept
              << " after_live " << s.live() << " after_cap " << rows.capacity()
              << " size " << rows.size() << "\n";
  }
  auto model_shape = [&](const char* name, const std::vector<std::string>& cols,
                          const std::vector<Cell>& proto, bool with_string) {
    Scope s;
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(kEdges));
    for (int i = 0; i < kEdges; ++i) {
      Row row;
      row.values.reserve(proto.size());
      for (const auto& cell : proto) {
        if (cell.kind == CellKind::Int) {
          row.values.push_back(make_int(1));
        } else if (cell.kind == CellKind::Double) {
          row.values.push_back(make_float(1.0));
        } else if (cell.kind == CellKind::String) {
          row.values.push_back(make_string("beauty"));
        } else {
          throw std::runtime_error("p0 cell");
        }
      }
      rows.emplace_back(std::move(row));
    }
    std::cout << "p0_heap " << name << " live " << s.live() << " cap " << rows.capacity()
              << " cell_cap " << rows.front().values.capacity() << " string " << with_string
              << "\n";
    std::vector<std::vector<Cell>> grid(kEdges, proto);
    auto ds = dataset_bytes(cols, grid);
    std::cout << "p0_thrift " << name << "_dataset " << ds << " lookup_resp " << wrap_response(ds, true)
              << "\n";
  };
  model_shape("keys4",
              {"buy._src", "buy._dst", "buy._rank", "buy._type"},
              {CInt(), CInt(), CInt(), CInt()},
              false);
  model_shape("keys_plus_item_type",
              {"buy._src", "buy._dst", "buy._rank", "buy._type", "buy.item_type"},
              {CInt(), CInt(), CInt(), CInt(), CStr(6)},
              true);
  model_shape("keys_item_type_ts",
              {"buy._src", "buy._dst", "buy._rank", "buy._type", "buy.item_type", "buy.ts"},
              {CInt(), CInt(), CInt(), CInt(), CStr(6), CInt()},
              true);

  // robin_hood flat set estimate: reserve(n) at 80% load, power-of-two capacity.
  auto rh = [](std::size_t n, std::size_t elem) {
    std::size_t need = (n * 10 + 7) / 8;  // ceil(n / 0.8)
    std::size_t cap = 1;
    while (cap < need) {
      cap <<= 1;
    }
    return cap * (elem + 1);  // slot + info byte
  };
  std::cout << "estimate robin_hood_rowptr_40415 " << rh(kEdges, sizeof(void*)) << "\n";
  std::cout << "estimate robin_hood_value_40415 " << rh(kEdges, sizeof(Val)) << "\n";
  std::cout << "estimate robin_hood_value_4000 " << rh(kUsers, sizeof(Val)) << "\n";

  std::cout << "done\n";
  return 0;
}
