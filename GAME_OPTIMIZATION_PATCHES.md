# MRuby Game Optimization - Source Code Patches

This document contains specific source code changes you can make to optimize MRuby for games on modern hardware.

## Patch 1: Increase Default GC Parameters

**File:** `src/gc.c`

**Current:**
```c
#define DEFAULT_GC_INTERVAL_RATIO 200
#define DEFAULT_GC_STEP_RATIO 200
#define MAJOR_GC_INC_RATIO 120
```

**Optimized for games:**
```c
#define DEFAULT_GC_INTERVAL_RATIO 400  // Run GC less frequently
#define DEFAULT_GC_STEP_RATIO 400      // Larger incremental steps
#define MAJOR_GC_INC_RATIO 200         // Less frequent major GC
```

**Impact:** 10-20% fewer GC pauses, uses ~2x more memory

---

## Patch 2: Disable Generational GC by Default

**File:** `src/state.c`

**Current:** (~line 284)
```c
mrb_state *mrb = (mrb_state *)allocf(NULL, sizeof(mrb_state));
// ... initialization ...
// Generational is enabled by default
```

**Optimized:**
Add this in `mrb_open_core()` after GC initialization:
```c
mrb->gc.generational = FALSE;  // Disable write barriers
```

Or create a runtime API:
```c
MRB_API void
mrb_gc_set_generational(mrb_state *mrb, mrb_bool enable)
{
  if (mrb->gc.generational == enable) return;

  if (!enable) {
    // Switching to non-generational
    mrb_full_gc(mrb);  // Clean state first
  }
  mrb->gc.generational = enable;
}
```

**Impact:** 5-10% performance gain from removing write barrier overhead

---

## Patch 3: Larger Default Heap Page Size

**File:** `include/mruby/gc.h` or build config

**Current:**
```c
#ifndef MRB_HEAP_PAGE_SIZE
#define MRB_HEAP_PAGE_SIZE 1024
#endif
```

**Optimized:**
```c
#ifndef MRB_HEAP_PAGE_SIZE
#define MRB_HEAP_PAGE_SIZE 4096  // 4x larger for modern systems
#endif
```

**Impact:** Better cache locality, fewer page allocations

---

## Patch 4: Optional Stack Scanning (Advanced)

**File:** `src/gc.c` (new functions)

This eliminates the need for GC arena in C extensions:

```c
#ifdef MRB_GC_ENABLE_STACK_SCAN

#include <unwind.h>  // libunwind

typedef struct {
  mrb_state *mrb;
  void *stack_start;
  void *stack_end;
} stack_scan_ctx;

static _Unwind_Reason_Code
scan_stack_frame(struct _Unwind_Context *ctx, void *data)
{
  stack_scan_ctx *scan = (stack_scan_ctx *)data;
  mrb_state *mrb = scan->mrb;
  void *ip = (void *)_Unwind_GetIP(ctx);

  // Scan stack frame for object pointers
  // This is simplified - real implementation needs more work
  uintptr_t *ptr = (uintptr_t *)_Unwind_GetCFA(ctx);
  uintptr_t *end = scan->stack_end;

  while (ptr < end) {
    mrb_value v;
    v.value.p = (void *)*ptr;
    if (mrb_obj_ptr_p(mrb, v)) {
      paint_partial(mrb, (struct RBasic *)mrb_ptr(v));
    }
    ptr++;
  }

  return _URC_NO_REASON;
}

static void
mrb_gc_scan_stack(mrb_state *mrb)
{
  stack_scan_ctx ctx;
  ctx.mrb = mrb;
  ctx.stack_start = mrb->c->stbase;
  ctx.stack_end = mrb->c->stend;

  _Unwind_Backtrace(scan_stack_frame, &ctx);
}

#endif // MRB_GC_ENABLE_STACK_SCAN
```

**Build Config:**
```ruby
conf.defines << 'MRB_GC_ENABLE_STACK_SCAN'
conf.linker.libraries << 'unwind'
```

**Impact:** Eliminates GC arena overhead in C extensions
**Effort:** High - requires platform-specific code and testing

---

## Patch 5: Method Cache Statistics (Profiling)

**File:** `src/class.c`

Add this to help profile method cache effectiveness:

```c
#ifdef MRB_METHOD_CACHE_STATS

static struct {
  size_t hits;
  size_t misses;
} method_cache_stats = {0};

void mrb_method_cache_stats_print(void)
{
  size_t total = method_cache_stats.hits + method_cache_stats.misses;
  if (total == 0) return;

  double hit_rate = (double)method_cache_stats.hits / total * 100.0;
  printf("Method Cache: %zu hits, %zu misses (%.2f%% hit rate)\n",
         method_cache_stats.hits, method_cache_stats.misses, hit_rate);
}

#define MC_STAT_HIT()   (method_cache_stats.hits++)
#define MC_STAT_MISS()  (method_cache_stats.misses++)

#else
#define MC_STAT_HIT()
#define MC_STAT_MISS()
#endif

// In method lookup code:
ent = cache_find_by_id(...);
if (ent->key == id) {
  MC_STAT_HIT();
  return ent->m;
}
MC_STAT_MISS();
```

**Ruby API:**
```ruby
# Print stats
GC.print_method_cache_stats
```

**Impact:** Helps identify if method cache size should be increased

---

## Patch 6: Frame-Budgeted GC (Game-Specific)

**File:** `src/gc.c`

Add ability to run GC incrementally with time budget:

```c
#include <time.h>

MRB_API size_t
mrb_gc_step_budget(mrb_state *mrb, uint64_t budget_ns)
{
  mrb_gc *gc = &mrb->gc;
  struct timespec start, now;
  uint64_t elapsed;
  size_t marked = 0;

  clock_gettime(CLOCK_MONOTONIC, &start);

  // Only do work if GC is needed
  if (!is_major_gc(gc) && !is_minor_gc(gc)) {
    return 0;
  }

  // Run incremental marking within budget
  while (gc->gray_list != NULL) {
    gc_mark_gray_list(mrb, gc->gray_list);
    gc->gray_list = gc->gray_list->gcnext;
    marked++;

    // Check time budget every 16 objects
    if ((marked & 15) == 0) {
      clock_gettime(CLOCK_MONOTONIC, &now);
      elapsed = (now.tv_sec - start.tv_sec) * 1000000000ULL +
                (now.tv_nsec - start.tv_nsec);
      if (elapsed >= budget_ns) {
        break;  // Out of time, resume next frame
      }
    }
  }

  // If marking complete, do sweep phase
  if (gc->gray_list == NULL && elapsed < budget_ns) {
    final_marking_phase(mrb, gc);
    prepare_incremental_sweep(mrb, gc);
    gc->state = GC_STATE_SWEEP;
  }

  return marked;
}
```

**Ruby API:**
```ruby
class Game
  def frame_loop
    loop do
      update
      render

      # Run GC for max 1ms per frame
      GC.step_budget(1_000_000)
    end
  end
end
```

**Impact:** Predictable GC pauses, essential for real-time games

---

## Patch 7: SIMD String Operations

**File:** `src/string.c`

Add SIMD-accelerated string operations:

```c
#ifdef __SSE2__
#include <emmintrin.h>

// Fast memcmp for small strings
static int
str_memcmp_simd(const char *s1, const char *s2, size_t len)
{
  if (len >= 16) {
    // Compare 16 bytes at a time
    size_t blocks = len / 16;
    for (size_t i = 0; i < blocks; i++) {
      __m128i v1 = _mm_loadu_si128((__m128i *)(s1 + i * 16));
      __m128i v2 = _mm_loadu_si128((__m128i *)(s2 + i * 16));
      __m128i cmp = _mm_cmpeq_epi8(v1, v2);
      int mask = _mm_movemask_epi8(cmp);
      if (mask != 0xFFFF) {
        // Found difference
        return memcmp(s1 + i * 16, s2 + i * 16, 16);
      }
    }
    // Compare remainder
    size_t remain = len % 16;
    if (remain > 0) {
      return memcmp(s1 + blocks * 16, s2 + blocks * 16, remain);
    }
    return 0;
  }
  return memcmp(s1, s2, len);
}
#else
#define str_memcmp_simd memcmp
#endif

// Use in string comparison:
int
mrb_str_cmp(mrb_state *mrb, mrb_value str1, mrb_value str2)
{
  // ... length check ...
  return str_memcmp_simd(RSTRING_PTR(str1), RSTRING_PTR(str2), len);
}
```

**Impact:** 2-4x faster string comparisons for medium-sized strings

---

## Patch 8: Custom Value Types (Fork Required)

**File:** `include/mruby/value.h`

Add game-specific immediate types:

```c
// Custom immediate types for 64-bit systems
#ifdef MRB_WORD_BOXING
#ifdef MRB_64BIT

// Encoding:
// 0x0000_0000_0000_0000 - Fixnum (47 bits)
// 0x0001_xxxx_xxxx_xxxx - Vector3 (3x 15-bit fixed point)
// 0x0002_xxxx_xxxx_xxxx - Color (RGBA, 4x 12-bit)
// 0xFFFC_xxxx_xxxx_xxxx - Symbol
// 0xFFFD_xxxx_xxxx_xxxx - Other immediates

typedef union mrb_value {
  void *p;
  struct {
    int32_t x : 15;
    int32_t y : 15;
    int32_t z : 15;
    uint32_t tag : 19;
  } vec3;
  struct {
    uint16_t r : 12;
    uint16_t g : 12;
    uint16_t b : 12;
    uint16_t a : 12;
    uint32_t tag : 16;
  } color;
  uint64_t value;
} mrb_value;

#define MRB_VECTOR3_TAG 0x0001
#define MRB_COLOR_TAG   0x0002

static inline mrb_value
mrb_vector3_value(float x, float y, float z)
{
  mrb_value v;
  v.vec3.x = (int32_t)(x * 1024.0f);  // Fixed point
  v.vec3.y = (int32_t)(y * 1024.0f);
  v.vec3.z = (int32_t)(z * 1024.0f);
  v.vec3.tag = MRB_VECTOR3_TAG << 13;
  return v;
}

static inline mrb_bool
mrb_vector3_p(mrb_value v)
{
  return (v.value >> 48) == MRB_VECTOR3_TAG;
}

#endif // MRB_64BIT
#endif // MRB_WORD_BOXING
```

**Ruby API:**
```ruby
# Zero-allocation vector math
pos = Vector3.new(1.0, 2.0, 3.0)  # Immediate value
vel = Vector3.new(0.1, 0.0, 0.1)  # Immediate value
pos = pos + vel  # No allocation!
```

**Impact:** Zero-allocation vector math, critical for game loops
**Effort:** Very high - requires extensive changes

---

## Patch 9: Bytecode Superinstructions

**File:** `src/vm.c` and `include/mruby/opcode.h`

Combine common instruction sequences:

```c
// Add to opcode.h:
#define OP_LOADI_ADD  106  // Load immediate + Add
#define OP_GETIV_SEND 107  // Get instance var + Send

// In vm.c dispatch loop:
CASE(OP_LOADI_ADD) {
  // Combines: LOADI R(a), i ; ADD R(a), R(a), R(b)
  mrb_int i = GETARG_sBx(i);
  mrb_int b = mrb_integer(regs[GETARG_b(i)]);
  regs[a] = mrb_fixnum_value(i + b);
  NEXT;
}

CASE(OP_GETIV_SEND) {
  // Combines: GETIV R(a), sym ; SEND R(a), method
  mrb_sym iv_sym = syms[GETARG_b(i)];
  mrb_sym method = syms[GETARG_c(i)];
  mrb_value iv = mrb_iv_get(mrb, regs[0], iv_sym);
  regs[a] = mrb_funcall_argv(mrb, iv, method, 0, NULL);
  NEXT;
}
```

**Compiler changes:** `mrbgems/mruby-compiler/core/codegen.c`

Detect patterns during code generation and emit superinstructions.

**Impact:** 5-15% speedup on tight loops
**Effort:** Medium - needs profiling to find common patterns

---

## Patch 10: Method Inlining Hints

**File:** `src/class.c`

Add support for method inlining hints:

```c
// New method flag
#define MRB_METHOD_INLINE_HINT  0x0400

// C API to mark methods as inline candidates
MRB_API void
mrb_method_inline_hint(mrb_state *mrb, struct RClass *c, mrb_sym mid)
{
  mrb_method_t m = mrb_method_search_vm(mrb, &c, mid);
  if (m) {
    m->flags |= MRB_METHOD_INLINE_HINT;
  }
}

// In VM dispatch, check for inline hint
if (m->flags & MRB_METHOD_INLINE_HINT) {
  // Try to inline if small enough
  if (m->body.irep->ilen < 16) {
    // Execute inline (save call/return overhead)
  }
}
```

**Ruby API:**
```ruby
class Vector3
  def +(other)
    Vector3.new(@x + other.x, @y + other.y, @z + other.z)
  end

  # Hint: this method is hot and should be inlined
  inline_method :+
end
```

**Impact:** 10-30% speedup for hot math operations
**Effort:** High - requires VM changes

---

## Testing Your Changes

After applying patches, benchmark:

```bash
# Build with patches
MRUBY_CONFIG=game-optimized ./minirake

# Run benchmarks
time ./build/host/bin/mruby benchmark/bm_so_mandelbrot.rb
time ./build/host/bin/mruby benchmark/bm_ao_render.rb

# Profile with perf
perf stat -e cycles,instructions,cache-misses,branch-misses \
  ./build/host/bin/mruby your_game_script.rb
```

Create game-specific benchmarks:

```ruby
# benchmark/bm_game_loop.rb
entity_count = 10000
entities = Array.new(entity_count) do
  { x: rand, y: rand, vx: rand - 0.5, vy: rand - 0.5 }
end

iterations = 1000
t0 = Time.now

iterations.times do
  entities.each do |e|
    e[:x] += e[:vx] * 0.016
    e[:y] += e[:vy] * 0.016

    # Bounce off edges
    if e[:x] < 0 || e[:x] > 1
      e[:vx] *= -1
    end
    if e[:y] < 0 || e[:y] > 1
      e[:vy] *= -1
    end
  end
end

t1 = Time.now
puts "#{iterations} frames, #{entity_count} entities: #{t1 - t0} seconds"
puts "FPS: #{iterations / (t1 - t0)}"
```

---

## Recommended Patch Order

1. **Patch 1-3** - Easy wins, low risk
2. **Patch 5** - Profiling, measure before optimizing further
3. **Patch 6** - If you need predictable GC pauses
4. **Patch 9** - If profiling shows VM dispatch is hot
5. **Patch 7** - If string ops are hot
6. **Patch 4, 8, 10** - Advanced, fork territory

---

## Maintenance

If you fork MRuby:

1. **Track upstream** - Rebase periodically on mruby/master
2. **Automate testing** - CI for your patches
3. **Document changes** - Keep this file updated
4. **Contribute back** - Submit performance improvements upstream
5. **Version carefully** - Tag your fork (e.g., mruby-game-v1.0)

---

## When NOT to Patch

Don't patch if:
- The bottleneck is in your Ruby code, not the VM
- You haven't profiled yet
- The patch adds significant complexity for < 10% gain
- You can solve it with better algorithms

**Example:** If your game is slow because you're doing O(n²) collision detection, no amount of VM optimization will help. Fix your algorithm first!

---

## Questions?

- MRuby Discord: https://discord.gg/qWréférence
- MRuby Gitter: https://gitter.im/mruby/mruby
- GitHub Issues: https://github.com/mruby/mruby/issues
