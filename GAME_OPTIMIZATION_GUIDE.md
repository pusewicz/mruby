# MRuby Game Optimization Guide

This guide outlines strategies for optimizing MRuby for game development on modern hardware, where you can skip embedded device constraints.

## Quick Start

Build with the game-optimized configuration:
```bash
MRUBY_CONFIG=game-optimized ./minirake
```

## Optimization Strategy

### Level 1: Build Configuration (No Code Changes) ✅

**Impact: 2-4x performance improvement**

Use `build_config/game-optimized.rb` which includes:

1. **Aggressive Compiler Flags**
   - `-O3` - Maximum optimization
   - `-march=native` - Use all CPU instructions (SSE, AVX, etc.)
   - `-flto` - Link-time optimization across compilation units

2. **Larger Memory Structures** (leverage modern RAM)
   - `MRB_HEAP_PAGE_SIZE=4096` - Better cache locality (default: 1024)
   - `MRB_METHOD_CACHE_SIZE=1024` - Fewer cache misses (default: 256)
   - `MRB_STACK_MAX=0x100000` - 1MB stack for deep recursion (default: ~250KB)
   - `MRB_GC_ARENA_SIZE=500` - Reduce GC protection overhead (default: 100)

3. **Performance-First Trade-offs**
   - `MRB_STACK_EXTEND_DOUBLING` - Exponential growth vs linear
   - `MRB_INT64` - 64-bit integers on 64-bit platforms
   - Keep method cache enabled (don't define `MRB_NO_METHOD_CACHE`)

**When to use:** Always start here. These changes are safe and reversible.

---

### Level 2: Code Modifications (Deeper Optimizations) 🔧

**Impact: 3-10x performance improvement (varies by workload)**

These require modifying MRuby source code:

#### 2.1 Optimize Garbage Collection

**Current Limitation:** Generational GC with write barriers adds ~5-10% overhead

**Optimization Options:**

A. **Disable Generational GC for Throughput**
   ```c
   // src/gc.c - Change default behavior
   mrb_state_field mrb_gc *gc = &mrb->gc;
   gc->generational = FALSE;  // Was TRUE by default
   ```
   - Eliminates write barrier overhead
   - Trade: Longer GC pauses, but faster allocation/mutation
   - Good for: Games with frame budgets, can pause during level loads

B. **Increase GC Interval Ratio**
   ```c
   // src/gc.c:60
   #define DEFAULT_GC_INTERVAL_RATIO 400  // Was 200
   ```
   - Run GC less frequently (when heap reaches 4x live set vs 2x)
   - Trade: More memory usage for fewer GC pauses

C. **Larger Heap Pages**
   ```c
   // Already configurable via MRB_HEAP_PAGE_SIZE
   // Consider 8192 or 16384 for games
   ```
   - Better cache locality
   - Fewer page allocations
   - Modern systems have plenty of RAM

#### 2.2 Add JIT Compilation Layer

**Current Limitation:** Pure bytecode interpretation

**Options:**

A. **Method-level JIT** (like MRI's MJIT)
   - Profile hot methods
   - Compile to native code via GCC/Clang
   - Cache compiled code
   - Fallback to bytecode for cold paths

B. **Tracing JIT** (like LuaJIT)
   - Identify hot loops
   - Compile hot traces to machine code
   - More complex but higher performance ceiling

**Estimated effort:** 3-6 months for basic JIT, 1-2 years for production-quality

**Alternative:** Use mruby/c project as reference (compiles ahead-of-time)

#### 2.3 Improve VM Dispatch

**Current:** Computed goto (fast) or switch (portable)

**Optimizations:**

A. **Superinstructions** - Combine common opcode sequences
   ```c
   // Example: LOADI + ADD -> LOADIADD
   case OP_LOADIADD:
     regs[a] = mrb_fixnum_value(GETARG_b(i) + GETARG_c(i));
     NEXT;
   ```

B. **Direct Threading** - Cache jump targets in bytecode
   - Eliminates dispatch overhead for hot loops
   - Requires bytecode rewriting

C. **Register Allocation** - Smarter use of VM registers
   - MRuby already does this reasonably well
   - Profile-guided optimization could help

#### 2.4 SIMD Optimizations

**Targets:** Array operations, string processing

```c
// Example: Fast array fill
void mrb_ary_fill_simd(mrb_value *start, mrb_value val, size_t len) {
  #ifdef __AVX2__
    // Use _mm256_store_si256 for bulk fill
  #else
    // Fallback to loop
  #endif
}
```

**Good for:** Particle systems, audio buffers, image processing

#### 2.5 Remove Embedded Constraints

**Changes:**

1. **Stack Scanning Instead of GC Arena**
   - Eliminates `mrb_gc_arena_save/restore` overhead
   - Requires platform-specific stack walking
   - MRI does this, but requires libunwind or similar

2. **Native Thread Support**
   - Add thread-local storage to mrb_state
   - Implement proper locking for shared objects
   - Significant architectural change

3. **Remove Fiber Context Switch Limitations**
   - Currently can't yield across C boundary
   - Would require saving/restoring C stack
   - Complex but doable with ucontext/fibers

---

### Level 3: Fork for Game-Specific Features 🚀

**When to fork:** If you need features that break MRuby's design philosophy

**Fork if you need:**

1. **Real-time Guarantees**
   - Deterministic GC pauses (hard real-time)
   - Memory pools for specific object types
   - Zero-allocation modes

2. **Tight Game Engine Integration**
   - Custom value types (Vector3, Quaternion as immediates)
   - Direct FFI without overhead
   - Memory-mapped game objects

3. **Incompatible Changes**
   - Different object model
   - Native compilation only (no bytecode)
   - Removing features (defined?, binding, etc.)

**Example Fork: "MRuby-Game"**

```c
// Custom immediate types
#define MRUBY_GAME_VECTOR3    // Pack 3 floats in value
#define MRUBY_GAME_QUATERNION // Pack 4 floats efficiently

// Zero-copy game object access
mrb_value mrb_entity_ref(mrb_state *mrb, Entity *ptr) {
  // Return direct pointer as mrb_value (no allocation)
}

// Frame-budgeted GC
void mrb_gc_frame_budget(mrb_state *mrb, uint64_t nanos) {
  // Run GC for at most 'nanos' nanoseconds
  // Return if not complete, resume next frame
}
```

---

## Benchmarking

**Before optimizing, profile:**

```bash
# Build with benchmarking
MRUBY_CONFIG=bench ./minirake

# Run benchmarks
./build/host/bin/mruby benchmark/bm_so_mandelbrot.rb
./build/host/bin/mruby benchmark/bm_ao_render.rb

# Profile with perf (Linux)
perf record -g ./build/host/bin/mruby your_game_script.rb
perf report
```

**Game-specific benchmarks:**

Create benchmarks that match your workload:
- Object allocation rates
- Method call overhead
- Array/Hash operations
- String operations
- Math operations

---

## Performance Comparison

### Expected Performance (relative to CRuby 3.x)

| Configuration | Speed | Memory | Startup | Notes |
|--------------|-------|--------|---------|-------|
| MRuby Default | 0.3-0.5x | 0.2x | 10x faster | Embedded-optimized |
| MRuby Game-Optimized | 0.5-0.8x | 0.4x | 8x faster | Build config only |
| MRuby + GC Tweaks | 0.6-1.0x | 0.5x | 8x faster | Code changes |
| MRuby + Basic JIT | 1.0-2.0x | 0.6x | 5x faster | Major effort |
| MRuby + Tracing JIT | 2.0-5.0x | 0.8x | 3x faster | LuaJIT-level |

### Comparison to Other Embedded Languages

| Language | Speed | Embed Size | Ease | Games Using It |
|----------|-------|------------|------|----------------|
| Lua | Fast | ~300KB | Easy | World of Warcraft, Roblox |
| LuaJIT | Very Fast | ~500KB | Easy | LÖVE, Neovim |
| MRuby | Medium | ~500KB | Easy | mruby/c projects |
| Python | Medium | ~10MB | Medium | EVE Online, Civilization IV |
| JavaScript (V8) | Very Fast | ~20MB | Hard | Unity (planned) |

---

## Recommendations

### For Indie Games (Small Team)

**Approach:** Tweak, Don't Fork

1. Use `game-optimized.rb` build configuration
2. Profile your specific workload
3. Make targeted GC adjustments if needed
4. Consider Lua/LuaJIT if raw speed is critical

**Why:** MRuby's Ruby syntax is more productive than Lua, worth small perf trade-off

### For AAA Games (Large Team)

**Approach:** Fork or Use Lua

1. If you love Ruby: Fork MRuby, add JIT + custom features
2. If you love speed: Use LuaJIT, it's battle-tested
3. If you need AOT: Consider mruby/c or custom compiler

**Why:** AAA games need predictable performance and can invest in tooling

### For Real-Time Games (60+ FPS requirement)

**Approach:** Hybrid Strategy

1. Use MRuby for game logic, tools, modding
2. Keep hot loops in C/C++ (rendering, physics, AI)
3. Use memory pools to avoid GC in critical paths
4. Consider frame-budgeted GC (custom fork)

**Why:** No scripting language is truly real-time, use for high-level glue

---

## Specific Optimizations by Game Type

### Turn-Based Games (e.g., RPG, Strategy)
- ✅ Default MRuby is fine
- ✅ Use generational GC (good for long-lived objects)
- ✅ Optimize for startup time (precompiled bytecode)

### Action Games (e.g., Platformer, Shooter)
- ✅ Use game-optimized config
- ✅ Disable generational GC (reduce write barrier overhead)
- ✅ Pool particle/bullet objects
- ⚠️ Keep hot loops in C/C++

### Open World / Simulation
- ✅ Large heap page size (8192+)
- ✅ Increase method cache (2048+)
- ✅ Consider JIT for hot paths
- ✅ Profile and optimize specific bottlenecks

---

## Code Examples

### Example 1: Zero-Allocation Particle System

```ruby
# Bad: Allocates on every frame
class ParticleSystem
  def update(dt)
    @particles.each do |p|
      p.position += p.velocity * dt  # Allocates Vector3
      p.velocity += @gravity * dt     # Allocates Vector3
    end
  end
end

# Good: Pre-allocate, mutate in-place (requires C extension)
class ParticleSystem
  def update(dt)
    particle_update_simd(@particles, dt, @gravity)  # C function
  end
end
```

### Example 2: Frame-Budgeted GC (Custom Fork)

```ruby
class Game
  def initialize
    # Allow 1ms of GC per frame
    GC.frame_budget = 1_000_000  # nanoseconds
  end

  def frame
    handle_input
    update_entities
    render
    GC.step  # Run GC for at most 1ms
  end
end
```

### Example 3: Pooled Objects

```ruby
# Pre-allocate object pools
class BulletPool
  def initialize(size = 1000)
    @bullets = Array.new(size) { Bullet.new }
    @free = @bullets.dup
  end

  def spawn(pos, vel)
    bullet = @free.pop or return nil
    bullet.activate(pos, vel)
    bullet
  end

  def recycle(bullet)
    bullet.deactivate
    @free.push(bullet)
  end
end
```

---

## Conclusion

**Can MRuby be optimized for games?** Yes, absolutely.

**Should you fork?** Only if:
- You need features incompatible with MRuby's design
- You have a team to maintain the fork
- You need bleeding-edge performance (JIT, SIMD, etc.)

**Start with:** Build configuration tweaks (Level 1)
**Then:** Profile and make targeted code changes (Level 2)
**Finally:** Fork only if necessary (Level 3)

**Alternative:** Consider Lua/LuaJIT if raw performance > Ruby syntax

---

## Resources

- MRuby Config Reference: `doc/guides/mrbconf.md`
- GC Internals: `src/gc.c`, `doc/guides/gc-arena-howto.md`
- VM Internals: `src/vm.c`, `doc/internal/opcode.md`
- Benchmarks: `benchmark/` directory
- mruby/c (AOT compiler): https://github.com/mrubyc/mrubyc

## Questions?

Open an issue or discussion on https://github.com/mruby/mruby
