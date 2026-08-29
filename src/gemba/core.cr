require "./lib_mgba"
require "./button"

module Gemba
  # A headless wrapper around one loaded ROM's mCore - opens a ROM, runs
  # frames, and hands back the video/audio buffers and bus memory as
  # plain Crystal data. No SDL, no Tk. Mirrors ruby-gba/gemba-core's own
  # GembaCore::Core, translated straight from its C ext
  # (gemba_core_ext.c) rather than reinterpreted.
  #
  # Deliberately NOT ported yet, versus gemba-core's own Core: save_dir
  # override (needs mDirectorySetMapOptions + modeling mCoreOptions,
  # neither needed by the Probe README example this bead's acceptance
  # criteria targets), BIOS loading, and the cycle-timing probes
  # (measure_frame_busy_cycles/measure_frame_work) - real gaps, not
  # forgotten, tracked for a follow-up once the core play path is
  # proven.
  class Core
    AUDIO_SAMPLE_RATE = 44100.0

    # mGBA's own internal audio ring buffer capacity, in samples per
    # channel - set once below via set_audio_buffer_size. blip_samples_avail
    # (see #audio_buffer) can never exceed this, so a caller sizing its own
    # buffer to AUDIO_BUFFER_SIZE * 2 (stereo, interleaved) int16 elements
    # is always enough to hold one frame's worth of drained samples.
    AUDIO_BUFFER_SIZE = 2048_u64

    # ~10s of history at ~60fps - the default #initialize's rewind_entries
    # falls back to; EmulationWorker overrides it from Config#rewind_seconds.
    DEFAULT_REWIND_ENTRIES = 600

    # mgba/core/serialize.h's SAVESTATE_* flags - a real @[Flags] enum
    # rather than the header's own bare numbers, so ALL (what
    # save_state_to_file/load_state_from_file always pass) is the OR of
    # every flag, computed by Crystal, not a magic 31 copied down.
    # Declaration order matches the header's own bit order exactly.
    @[Flags]
    enum SaveStateFlags
      Screenshot
      SaveData
      Cheats
      Rtc
      Metadata
    end

    @@logger_installed = false

    getter width : Int32
    getter height : Int32

    @core : LibMgba::MCore*
    @video_buffer : Slice(UInt32)
    @destroyed : Bool
    @rewind_ctx : LibMgba::MCoreRewindContext*

    # struct mCoreRewindContext's real size depends on build flags this
    # project's own vendored mgba always sets - 176 bytes on Linux, 192
    # on macOS, both confirmed with a C sizeof probe that #includes
    # mgba/flags.h before mgba/core/rewind.h (skip flags.h and
    # mgba-util/threading.h silently DEFINES DISABLE_THREADING itself,
    # reporting 56 regardless of how the library was actually built -
    # exactly how gemba's own lib_mgba.cr got this wrong before: a
    # 56-byte `struct MCoreRewindContext` embedded BY VALUE in every
    # Core, with mCoreRewindContextInit/Append/Restore's real writes
    # landing up to ~150 bytes past the end of that region - into
    # whatever Boehm GC object happened to sit next to a Core's own
    # allocation. Silent heap corruption that moved with allocation
    # layout, one zeroed byte at a time - confirmed as the source of a
    # long-running series of seemingly random Hash corruption crashes
    # throughout this codebase's own test suite.
    #
    # Heap-allocated here instead, well past either real size, rather
    # than ever declared as a sized Crystal struct again.
    REWIND_CONTEXT_SIZE = 512

    def initialize(rom_path : String, rewind_entries : Int32 = DEFAULT_REWIND_ENTRIES)
      unless @@logger_installed
        LibMgba.gemba_install_null_logger
        @@logger_installed = true
      end

      core = LibMgba.mCoreFind(rom_path)
      raise ArgumentError.new("mCoreFind failed - unsupported ROM: #{rom_path}") if core.null?
      vp = core.as(Void*)
      raise "mCore init failed" unless core.value.init.call(vp)

      # GBACoreInit defaults rtc.override to RTC_NO_OVERRIDE, breaking
      # RTC carts. Must set to WallclockOffset.
      core.value.rtc.override = LibMgba::MRTCGenericType::WallclockOffset

      LibMgba.mCoreInitConfig(core, Pointer(LibC::Char).null)

      w = uninitialized UInt32
      h = uninitialized UInt32
      core.value.desired_video_dimensions.call(vp, pointerof(w), pointerof(h))

      video_buffer = Slice(UInt32).new(w.to_i32 * h.to_i32, 0_u32)
      core.value.set_video_buffer.call(vp, video_buffer.to_unsafe, w.to_u64)
      core.value.set_audio_buffer_size.call(vp, AUDIO_BUFFER_SIZE)

      unless LibMgba.mCoreLoadFile(core, rom_path)
        core.value.deinit.call(vp)
        raise ArgumentError.new("failed to load ROM: #{rom_path}")
      end

      core.value.reset.call(vp)

      # Re-query dimensions post-reset: for GB/GBC, the pre-load query
      # answers the SGB frame size (256x224, board is still nil at that
      # point) - after reset the real model is known. Reallocate if it
      # shrank, matching gemba-core's own initialize step 8b.
      w2 = uninitialized UInt32
      h2 = uninitialized UInt32
      core.value.desired_video_dimensions.call(vp, pointerof(w2), pointerof(h2))
      if w2 != w || h2 != h
        video_buffer = Slice(UInt32).new(w2.to_i32 * h2.to_i32, 0_u32)
        core.value.set_video_buffer.call(vp, video_buffer.to_unsafe, w2.to_u64)
      end

      LibMgba.mCoreAutoloadSave(core)

      left = core.value.get_audio_channel.call(vp, 0)
      right = core.value.get_audio_channel.call(vp, 1)
      raise "mGBA audio channels not available" if left.null? || right.null?
      frequency = core.value.frequency.call(vp)
      LibMgba.blip_set_rates(left, frequency.to_f64, AUDIO_SAMPLE_RATE)
      LibMgba.blip_set_rates(right, frequency.to_f64, AUDIO_SAMPLE_RATE)

      @core = core
      @width = w2.to_i32
      @height = h2.to_i32
      @video_buffer = video_buffer
      @destroyed = false

      @rewind_ctx = Pointer(UInt8).malloc(REWIND_CONTEXT_SIZE).as(LibMgba::MCoreRewindContext*)
      LibMgba.mCoreRewindContextInit(@rewind_ctx, rewind_entries.to_u64, false)
    end

    def run_frame : Nil
      raise_if_destroyed!
      @core.value.run_frame.call(cp)
    end

    # The current frame's pixels, XBGR8 (color_t) - byte 0 red, 1 green,
    # 2 blue, 3 unused padding, little-endian, one UInt32 per pixel,
    # width * height of them. The SAME slice every call (mGBA writes
    # into it in place) - copy it if you need to keep this frame after
    # the next #run_frame.
    def video_buffer : Slice(UInt32)
      raise_if_destroyed!
      @video_buffer
    end

    # Interleaved stereo Int16 samples (L R L R ...) drained since the
    # last call - empty once nothing new is buffered.
    def audio_buffer : Slice(Int16)
      raise_if_destroyed!
      left = @core.value.get_audio_channel.call(cp, 0)
      right = @core.value.get_audio_channel.call(cp, 1)
      return Slice(Int16).empty if left.null? || right.null?

      avail = LibMgba.blip_samples_avail(left)
      return Slice(Int16).empty if avail <= 0

      buf = Slice(Int16).new(avail * 2, 0_i16)
      LibMgba.blip_read_samples(left, buf.to_unsafe, avail, 1)
      LibMgba.blip_read_samples(right, buf.to_unsafe + 1, avail, 1)
      buf
    end

    def keys=(bitmask : UInt32) : UInt32
      raise_if_destroyed!
      @core.value.set_keys.call(cp, bitmask)
      bitmask
    end

    def keys=(buttons : Button) : Button
      self.keys = buttons.value.to_u32
      buttons
    end

    def title : String
      raise_if_destroyed!
      buf = Bytes.new(16, 0_u8)
      @core.value.get_game_title.call(cp, buf.to_unsafe)
      String.new(buf).rstrip('\0').rstrip(' ')
    end

    def game_code : String
      raise_if_destroyed!
      buf = Bytes.new(16, 0_u8)
      @core.value.get_game_code.call(cp, buf.to_unsafe)
      String.new(buf).rstrip('\0').rstrip(' ')
    end

    def checksum : UInt32
      raise_if_destroyed!
      crc = uninitialized UInt32
      @core.value.checksum.call(cp, pointerof(crc).as(Void*), LibMgba::ChecksumType::CRC32)
      crc
    end

    def platform : LibMgba::Platform
      raise_if_destroyed!
      @core.value.platform.call(cp)
    end

    def rom_size : UInt64
      raise_if_destroyed!
      @core.value.rom_size.call(cp)
    end

    def rtc_override : LibMgba::MRTCGenericType
      raise_if_destroyed!
      @core.value.rtc.override
    end

    # Snapshots the current state into rewind history - call once per
    # frame BEFORE #run_frame (mirrors mgba/core/thread.c's own
    # _frameStarted, the reference this port's rewind loop follows).
    def rewind_append : Nil
      raise_if_destroyed!
      LibMgba.mCoreRewindAppend(@rewind_ctx, @core)
    end

    # Loads the most recent rewind snapshot, moving the pointer one
    # entry further back for next time. Returns false once history is
    # exhausted - the caller's cue to fall back to #rewind_append instead
    # (same fallback _frameStarted itself does).
    def rewind_restore : Bool
      raise_if_destroyed!
      LibMgba.mCoreRewindRestore(@rewind_ctx, @core)
    end

    def bus_read8(address : UInt32) : UInt8
      raise_if_destroyed!
      @core.value.bus_read8.call(cp, address).to_u8
    end

    def bus_read16(address : UInt32) : UInt16
      raise_if_destroyed!
      @core.value.bus_read16.call(cp, address).to_u16
    end

    def bus_read32(address : UInt32) : UInt32
      raise_if_destroyed!
      @core.value.bus_read32.call(cp, address)
    end

    # Saves the complete emulator state (SAVESTATE_ALL: screenshot,
    # save data, cheats, RTC, metadata) to path. Returns false rather
    # than raising if libmgba itself reports failure (a full disk, a
    # permissions problem) - matches gemba-core's own C ext, which
    # never had access to a real path-writability check ahead of time
    # either.
    def save_state_to_file(path : String) : Bool
      raise_if_destroyed!
      vf = LibMgba.VFileOpen(path, LibC::O_CREAT | LibC::O_TRUNC | LibC::O_WRONLY)
      raise "cannot open state file for writing: #{path}" if vf.null?
      ok = LibMgba.mCoreSaveStateNamed(@core, vf.as(Void*), SaveStateFlags::All.value)
      vf.value.close.call(vf.as(Void*))
      ok
    end

    def load_state_from_file(path : String) : Bool
      raise_if_destroyed!
      vf = LibMgba.VFileOpen(path, LibC::O_RDONLY)
      return false if vf.null?
      ok = LibMgba.mCoreLoadStateNamed(@core, vf.as(Void*), SaveStateFlags::All.value)
      vf.value.close.call(vf.as(Void*))
      ok
    end

    def destroy : Nil
      return if @destroyed
      @destroyed = true
      LibMgba.mCoreRewindContextDeinit(@rewind_ctx)
      @core.value.deinit.call(cp)
    end

    def destroyed? : Bool
      @destroyed
    end

    # @core cast to the Void* every function-pointer field's first
    # parameter expects - MCore* doesn't implicitly convert the way a
    # C caller's `struct mCore*` would.
    private def cp : Void*
      @core.as(Void*)
    end

    private def raise_if_destroyed! : Nil
      raise "mGBA core has been destroyed" if @destroyed
    end
  end
end
