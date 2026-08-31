require "../spec_helper"

private FILL_ROM        = File.join(__DIR__, "..", "fixtures", "fill.gba")
private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")

# Built from ruby-gba's own examples/pong.rb, rather than an opaque
# prebuilt fixture - its RAM layout is fully known, which fill.gba/
# space_blast.gba's isn't. Addresses below are from rom.var_addresses,
# not guessed.
private PONG_ROM    = File.join(__DIR__, "..", "fixtures", "pong.gba")
private PONG_BALL_X = 0x03000008_u32
private PONG_BALL_Y = 0x0300000c_u32
private PONG_STATE  = 0x03000028_u32

# Holds Start for a few frames then releases it - pong.rb's title scene
# advances to :playing (state 1) on a press, same as a real player would.
private def pong_press_start(core : Gemba::Core) : Nil
  5.times { core.keys = 0_u32; core.run_frame }
  3.times { core.keys = Gemba::Button::Start; core.run_frame }
  core.keys = 0_u32
  core.run_frame
end

describe Gemba::Core do
  it "loads a ROM and reports its dimensions/title/platform" do
    core = Gemba::Core.new(FILL_ROM)
    core.width.should eq 240
    core.height.should eq 160
    core.title.should eq "FILL"
    core.platform.should eq LibMgba::Platform::GBA
    core.rom_size.should be > 0
    core.destroy
  end

  it "defaults the RTC source to wall-clock time" do
    core = Gemba::Core.new(FILL_ROM)
    core.rtc_override.should eq LibMgba::MRTCGenericType::WallclockOffset
    core.destroy
  end

  it "#run_frame advances emulation and #video_buffer reflects it" do
    core = Gemba::Core.new(FILL_ROM)
    core.run_frame
    buf = core.video_buffer
    buf.size.should eq 240 * 160
    buf[0].should_not eq 0_u32 # red pixel, not the zeroed initial buffer
    core.destroy
  end

  it "#bus_read8/16/32 read real GBA bus memory" do
    core = Gemba::Core.new(FILL_ROM)
    core.run_frame
    # BIOS/ROM header region (0x08000000+) is always mapped and readable
    # regardless of what the ROM itself does.
    core.bus_read32(0x08000000).should be_a(UInt32)
    core.bus_read16(0x08000000).should be_a(UInt16)
    core.bus_read8(0x08000000).should be_a(UInt8)
    core.destroy
  end

  # mGBA's busRead8/16 return uint32_t, and two kinds of read put bits
  # above the nominal width: a halfword load at an odd address comes
  # back byte-rotated (GBA ROR semantics), and a load from unmapped
  # space returns the CPU's 32-bit prefetch word (open bus). C callers
  # truncate silently; a checked Crystal narrowing raised OverflowError
  # on both, live, from the rcheevos peek callback.
  it "#bus_read16/8 truncate a rotated (misaligned) or open-bus value instead of raising" do
    core = Gemba::Core.new(FILL_ROM)
    core.run_frame
    aligned = core.bus_read16(0x08000000)
    rotated = core.bus_read16(0x08000001) # odd address: ROR by 8
    rotated.should be_a(UInt16)
    # The rotation is real, not a no-op: ROR by 8 leaves the aligned
    # halfword's high byte as the low byte of what survives truncation
    # (its low byte moved to bits 16-23 - the part that overflowed).
    rotated.should eq(aligned >> 8)
    core.bus_read16(0x10000000).should be_a(UInt16) # past every region: open bus
    core.bus_read8(0x10000001).should be_a(UInt8)
    core.destroy
  end

  it "#checksum returns a non-zero CRC32 for a real ROM" do
    core = Gemba::Core.new(FILL_ROM)
    core.checksum.should be > 0
    core.destroy
  end

  it "#destroy is idempotent and #destroyed? reflects it" do
    core = Gemba::Core.new(FILL_ROM)
    core.destroyed?.should be_false
    core.destroy
    core.destroyed?.should be_true
    core.destroy # no raise
  end

  it "raises once destroyed" do
    core = Gemba::Core.new(FILL_ROM)
    core.destroy
    expect_raises(Exception, /destroyed/) { core.run_frame }
    expect_raises(Exception, /destroyed/) { core.bus_read8(0) }
  end

  it "raises ArgumentError for an unsupported/nonexistent ROM path" do
    expect_raises(ArgumentError) { Gemba::Core.new("/nonexistent/path.gba") }
  end

  # Verified by determinism rather than a direct buffer comparison right
  # after load: mCoreLoadStateNamed restores CPU/PPU/memory state, but
  # the video buffer itself is only repainted by the NEXT #run_frame -
  # so "run one frame from the saved point" has to reproduce the exact
  # same pixels as "run one frame right after saving" did, no matter how
  # much unrelated emulation happened in between. Neither path ever
  # calls #keys=, so both see identical (default/unset) input throughout
  # - the only thing that could make them diverge is the save/load
  # round-trip itself being lossy.
  it "#save_state_to_file/#load_state_from_file round-trip emulator state" do
    core = Gemba::Core.new(SPACE_BLAST_ROM)
    path = File.tempname("gemba_save_state_spec", ".ss")

    begin
      10.times { core.run_frame }
      core.save_state_to_file(path).should be_true

      # The state file is a real PNG (screenshot as the visible image,
      # state in private chunks) - what SaveStatePicker's direct
      # .ss-as-thumbnail loading relies on. See Core#save_state_to_file.
      png_magic = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      File.read(path).to_slice[0, png_magic.size].should eq png_magic

      core.run_frame
      frame_after_save = core.video_buffer.dup

      20.times { core.run_frame }

      core.load_state_from_file(path).should be_true
      core.run_frame
      core.video_buffer.should eq frame_after_save
    ensure
      core.destroy
      File.delete?(path)
    end
  end

  # The test above only proves the VIDEO layer round-trips. pong.gba's known
  # RAM layout (see PONG_BALL_X/Y above) lets this one also prove memory
  # (the ball's position, which moves every frame once in :playing) and
  # audio (the background song's real, non-silent PCM) round-trip too - not
  # just the picture. #audio_buffer drains "since the last call" (see its
  # own doc comment), so it's called every frame throughout, same as
  # production (EmulationWorker#run does the same) - anything less and a
  # note's samples can fall out of the buffer before a single end-of-test
  # read ever sees them.
  it "#save_state_to_file/#load_state_from_file round-trip memory and audio, not just video" do
    core = Gemba::Core.new(PONG_ROM)
    path = File.tempname("gemba_save_state_spec", ".ss")

    begin
      pong_press_start(core)
      core.bus_read32(PONG_STATE).should eq 1 # confirms we're really in :playing

      10.times do
        core.run_frame
        core.audio_buffer # drain every frame - see the comment above
      end
      core.save_state_to_file(path).should be_true

      core.run_frame
      frame_after_save = core.video_buffer.dup
      ball_x_after_save = core.bus_read32(PONG_BALL_X)
      ball_y_after_save = core.bus_read32(PONG_BALL_Y)
      audio_after_save = core.audio_buffer.dup
      audio_after_save.all?(&.zero?).should be_false # the song really is playing here

      20.times do
        core.run_frame
        core.audio_buffer # drain every frame - see the comment above
      end
      core.bus_read32(PONG_BALL_X).should_not eq ball_x_after_save # confirms real divergence

      core.load_state_from_file(path).should be_true
      core.run_frame
      core.video_buffer.should eq frame_after_save
      core.bus_read32(PONG_BALL_X).should eq ball_x_after_save
      core.bus_read32(PONG_BALL_Y).should eq ball_y_after_save

      # mGBA's blip resampler isn't part of serialized state, so exact PCM
      # samples differ across save/load - non-silence is the honest bar.
      core.audio_buffer.all?(&.zero?).should be_false
    ensure
      core.destroy
      File.delete?(path)
    end
  end

  it "#load_state_from_file returns false for a path that doesn't exist" do
    core = Gemba::Core.new(FILL_ROM)
    core.load_state_from_file("/nonexistent/state.ss").should be_false
    core.destroy
  end

  # #rewind_append/#rewind_restore mirror mgba/core/thread.c's own
  # _frameStarted exactly: append snapshots the state BEFORE a frame
  # runs, so appending then running N times leaves history holding "the
  # state that produced positions[i]" for each i. One #rewind_restore
  # loads the second-most-recent snapshot (mCoreRewindRestore's own
  # previousState/currentState swap keeps one entry "ahead"), so
  # running one frame from it reproduces positions[-2], not positions[-1].
  it "#rewind_append/#rewind_restore round-trip memory via mGBA's own patch history" do
    core = Gemba::Core.new(PONG_ROM)

    begin
      pong_press_start(core)
      core.bus_read32(PONG_STATE).should eq 1 # confirms we're really in :playing

      positions = [] of UInt32
      20.times do
        core.rewind_append
        core.run_frame
        positions << core.bus_read32(PONG_BALL_X)
      end
      positions.last.should_not eq positions[-2] # confirms real movement between frames

      core.rewind_restore.should be_true
      core.run_frame
      core.bus_read32(PONG_BALL_X).should eq positions[-2]
    ensure
      core.destroy
    end
  end

  it "#rewind_restore returns false once history is exhausted" do
    core = Gemba::Core.new(FILL_ROM, rewind_entries: 3)

    begin
      5.times do
        core.rewind_append
        core.run_frame
      end

      core.rewind_restore.should be_true
      core.rewind_restore.should be_true
      core.rewind_restore.should be_true
      core.rewind_restore.should be_false
    ensure
      core.destroy
    end
  end
end
