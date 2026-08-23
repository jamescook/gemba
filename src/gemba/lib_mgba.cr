# Raw libmgba bindings - straight `lib` FFI, the same approach this
# project already uses for Tcl/Tk (src/tryst/interp.cr), with ONE
# deliberate exception: native/null_logger.c, a single C function
# whose real signature (a va_list parameter) Crystal cannot express at
# all - see its own header comment. Compile it once with
# `cc -c -I vendor/mgba-install/include native/null_logger.c -o native/null_logger.o`
# before building anything that requires this file.
#
# struct MCore mirrors mgba/core/core.h's struct mCore FIELD FOR FIELD,
# in its exact declared order, through busRead32 - the last field this
# shard calls. Field offsets are FFI-critical and vary by platform and
# build flags (MINIMAL_CORE, USE_DEBUGGERS), so every offset was
# verified with a sizeof/offsetof probe against a real, from-source
# build (see gemba/vendor/) rather than assumed. dirs/inputMap/config/
# opts/rtc are embedded BY VALUE before the function pointers begin;
# get any of their sizes wrong and every function pointer after them
# silently reads from the wrong offset. Their CONTENTS are never read
# here, only their SIZE matters (hence UInt8[N] rather than modeling
# their own internals).
#
# core.h also declares supportsFeature/setSync/loadConfig/
# reloadConfigOption/setVideoGLTex/getPixels/putPixels/
# getAudioBufferSize/addCoreCallbacks/clearCoreCallbacks/setAVStream/
# isROM/loadROM/loadSave/loadTemporarySave/unloadROM/selectBIOS/
# loadPatch/runLoop/addKeys/clearKeys/getKeys/frameCounter/
# setPeripheral between the fields this shard actually calls - each is
# declared here as a plain Void* placeholder in EXACT field order
# (never called through), which is what keeps every real field's own
# offset correct without needing to know their individual signatures.
#
# The .a is referenced by its full path, not -L<dir> -lmgba: this
# machine also has an unrelated, stale full-fat libmgba.a on the linker
# search path, and the full path avoids picking that one up instead of
# this shard's own vendored build.
@[Link(ldflags: "#{__DIR__}/../../native/null_logger.o #{__DIR__}/../../vendor/mgba-install/lib/libmgba.a `pkg-config --libs libpng libzip 2>/dev/null || echo -lpng -lzip` -lz -lm -lpthread")]
{% if flag?(:darwin) %}
  @[Link(framework: "CoreFoundation")]
{% end %}
lib LibMgba
  alias ColorT = UInt32

  enum Platform : Int32
    None = -1
    GBA  =  0
    GB   =  1
  end

  enum ChecksumType : Int32
    CRC32 = 0
  end

  struct MCore
    cpu : Void*
    board : Void*
    timing : Void*
    debugger : Void*
    symbol_table : Void*
    video_logger : Void*

    # mDirectorySet's own size is NOT the same across platforms, despite
    # identical MINIMAL_CORE/USE_DEBUGGERS build flags: 4152 bytes on
    # Linux vs 1080 on macOS, almost certainly PATH_MAX baked into its
    # own path buffers. Every offset from here on shifts by that delta -
    # the one and only per-platform gate needed; every other embedded
    # struct matched exactly. A real compile error on an unverified OS
    # beats a silent wrong offset and a segfault.
    {% if flag?(:darwin) %}
      dirs : UInt8[1080]
    {% elsif flag?(:linux) %}
      dirs : UInt8[4152]
    {% else %}
      {% raise "gemba's LibMgba::MCore has only been verified on darwin and linux - re-run the sizeof/offsetof probe (see this file's own doc comment) before trusting it on another OS" %}
    {% end %}
    input_map : UInt8[24]
    config : UInt8[440]
    opts : UInt8[120]
    rtc : UInt8[64]

    init : Void* -> Bool
    deinit : Void* -> Void

    platform : Void* -> Platform
    supports_feature : Void*

    set_sync : Void*
    load_config : Void*
    reload_config_option : Void*

    desired_video_dimensions : (Void*, UInt32*, UInt32*) -> Void
    set_video_buffer : (Void*, ColorT*, LibC::SizeT) -> Void
    set_video_gl_tex : Void*

    get_pixels : Void*
    put_pixels : Void*

    get_audio_channel : (Void*, Int32) -> Void*
    set_audio_buffer_size : (Void*, LibC::SizeT) -> Void
    get_audio_buffer_size : Void*

    add_core_callbacks : Void*
    clear_core_callbacks : Void*
    set_av_stream : Void*

    is_rom : Void*
    load_rom : Void*
    load_save : Void*
    load_temporary_save : Void*
    unload_rom : Void*
    rom_size : Void* -> LibC::SizeT
    checksum : (Void*, Void*, ChecksumType) -> Void

    load_bios : (Void*, Void*, Int32) -> Bool
    select_bios : Void*

    load_patch : Void*

    reset : Void* -> Void
    run_frame : Void* -> Void
    run_loop : Void*
    step : Void* -> Void

    state_size : Void* -> LibC::SizeT
    load_state : (Void*, Void*) -> Bool
    save_state : (Void*, Void*) -> Bool

    set_keys : (Void*, UInt32) -> Void
    add_keys : Void*
    clear_keys : Void*
    get_keys : Void*

    frame_counter : Void*
    frame_cycles : Void* -> Int32
    frequency : Void* -> Int32

    get_game_title : (Void*, UInt8*) -> Void
    get_game_code : (Void*, UInt8*) -> Void

    set_peripheral : Void*

    bus_read8 : (Void*, UInt32) -> UInt32
    bus_read16 : (Void*, UInt32) -> UInt32
    bus_read32 : (Void*, UInt32) -> UInt32
  end

  fun mCoreFind(path : LibC::Char*) : MCore*
  fun mCoreLoadFile(core : MCore*, path : LibC::Char*) : Bool
  fun mCoreInitConfig(core : MCore*, port : LibC::Char*) : Void
  fun mCoreAutoloadSave(core : MCore*) : Bool
  fun mCoreSaveStateNamed(core : MCore*, vf : Void*, flags : Int32) : Bool
  fun mCoreLoadStateNamed(core : MCore*, vf : Void*, flags : Int32) : Bool

  # mgba-util/vfs.h's struct VFile - only its first field (close is
  # ALWAYS the first member of the real struct's function-pointer table,
  # confirmed against the real header), since that's the only one gemba
  # ever calls. Safe to mirror just the prefix: Crystal only reads what
  # it's told to, and everything this declares starts at the real
  # struct's own offset 0.
  struct VFile
    close : Void* -> Bool
  end

  fun VFileOpen(path : LibC::Char*, flags : Int32) : VFile*

  # blip_buf - libmgba's audio ring buffer. Opaque; only ever handed a
  # pointer libmgba itself returned (getAudioChannel), never allocated
  # here.
  fun blip_samples_avail(buf : Void*) : Int32
  fun blip_read_samples(buf : Void*, out_samples : Int16*, count : Int32, stereo : Int32) : Int32
  fun blip_set_rates(buf : Void*, clock_rate : Float64, sample_rate : Float64) : Void

  # Installs a no-op logger - without one, mGBA's default (uninitialized)
  # logger crashes the first time anything tries to log. Defined in
  # native/null_logger.c, not here: struct mLogger's .log field takes a
  # va_list argument, which has no Crystal FFI representation on any
  # platform - see that file's own header comment.
  fun gemba_install_null_logger : Void
end
