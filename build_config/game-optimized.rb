MRuby::Build.new('game-optimized') do |conf|
  # Use GCC/Clang for best performance
  toolchain :gcc

  # Aggressive compiler optimizations
  conf.cc.flags << '-O3'
  conf.cc.flags << '-march=native'        # Use all CPU features
  conf.cc.flags << '-mtune=native'
  conf.cc.flags << '-flto'                # Link-time optimization
  conf.cc.flags << '-fomit-frame-pointer'

  # Game-oriented defines
  conf.defines << 'MRB_STACK_EXTEND_DOUBLING'  # Exponential stack growth
  conf.defines << 'MRB_HEAP_PAGE_SIZE=4096'    # 4x larger heap pages
  conf.defines << 'MRB_METHOD_CACHE_SIZE=1024' # 4x larger method cache
  conf.defines << 'MRB_STACK_MAX=0x100000'     # 1MB stack (4x default)
  conf.defines << 'MRB_GC_ARENA_SIZE=500'      # 5x default arena

  # Disable memory-saving features
  # conf.defines << 'MRB_GC_TURN_OFF_GENERATIONAL' # Trade GC pauses for throughput
  conf.defines << 'MRB_MALLOC_TRIM'             # Return memory to OS

  # Keep UTF-8 support for modern games
  conf.defines << 'MRB_UTF8_STRING'

  # Use 64-bit integers on 64-bit platforms
  conf.defines << 'MRB_INT64'

  # Increase limits
  conf.defines << 'MRB_STR_LENGTH_MAX=16777216'  # 16MB strings
  conf.defines << 'MRB_ARY_LENGTH_MAX=16777216'  # 16MB arrays
  conf.defines << 'KHASH_DEFAULT_SIZE=64'        # Larger hash buckets
  conf.defines << 'MRB_FUNCALL_ARGC_MAX=32'      # More function args

  # Full feature set
  conf.gembox 'default'

  # Add game-useful gems
  conf.gem core: 'mruby-numeric-ext'
  conf.gem core: 'mruby-random'
  conf.gem core: 'mruby-math'
  conf.gem core: 'mruby-time'
  conf.gem core: 'mruby-pack'
end
