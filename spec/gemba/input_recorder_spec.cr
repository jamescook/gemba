require "../spec_helper"
require "file_utils"

private FILL_ROM        = File.join(__DIR__, "..", "fixtures", "fill.gba")
private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")

# See core_spec.cr - pong.gba's RAM layout is fully known (built from
# ruby-gba's examples/pong.rb), which is what lets the determinism test
# below assert on real gameplay state rather than a screen hash.
private PONG_ROM    = File.join(__DIR__, "..", "fixtures", "pong.gba")
private PONG_BALL_X = 0x03000008_u32
private PONG_BALL_Y = 0x0300000c_u32
private PONG_STATE  = 0x03000028_u32

private def with_tempdir(&)
  dir = File.tempname("input_recorder_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Runs one frame the way the emulation loop does while recording:
# capture the mask the frame is about to run under, apply it, step.
private def record_frame(recorder : Gemba::InputRecorder, core : Gemba::Core, mask : UInt32) : Nil
  recorder.capture(mask)
  core.keys = mask
  core.run_frame
end

describe Gemba::InputRecorder do
  it "writes ruby gemba's .gir format: header, hex mask lines, anchor state, rewritten frame_count" do
    with_tempdir do |dir|
      core = Gemba::Core.new(FILL_ROM)
      begin
        path = File.join(dir, "session.gir")
        recorder = Gemba::InputRecorder.new(path, core, rom_path: FILL_ROM)
        recorder.recording?.should be_false
        recorder.start
        recorder.recording?.should be_true
        recorder.anchor_state_path.should eq File.join(dir, "session.state")
        File.exists?(recorder.anchor_state_path).should be_true

        [0x001_u32, 0x3ff_u32, 0x000_u32, 0x010_u32].each { |mask| record_frame(recorder, core, mask) }
        recorder.stop
        recorder.recording?.should be_false
        recorder.frame_count.should eq 4

        lines = File.read_lines(path)
        lines[0].should eq "# GEMBA INPUT RECORDING v1"
        lines.should contain "# rom_checksum: #{core.checksum}"
        lines.should contain "# game_code: #{core.game_code}"
        lines.should contain "# rom_path: #{FILL_ROM}"
        # Rewritten in place on the clean stop - not the 0000000000
        # placeholder #start wrote.
        lines.should contain "# frame_count: 0000000004"
        lines.should contain "# anchor_state: session.state"
        separator = lines.index("---").should_not be_nil
        lines[(separator + 1)..].should eq ["001", "3ff", "000", "010"]
      ensure
        core.destroy
      end
    end
  end
end

describe Gemba::InputReplayer do
  it "parses a recording back: header fields, per-frame masks, and a passing checksum check" do
    with_tempdir do |dir|
      core = Gemba::Core.new(FILL_ROM)
      begin
        path = File.join(dir, "session.gir")
        recorder = Gemba::InputRecorder.new(path, core, rom_path: FILL_ROM)
        recorder.start
        [0x001_u32, 0x3ff_u32].each { |mask| record_frame(recorder, core, mask) }
        recorder.stop

        replayer = Gemba::InputReplayer.new(path)
        replayer.rom_checksum.should eq core.checksum
        replayer.game_code.should eq core.game_code
        replayer.rom_path.should eq FILL_ROM
        replayer.header_frame_count.should eq 2
        replayer.frame_count.should eq 2
        replayer.anchor_state_path.should eq recorder.anchor_state_path
        replayer.bitmask_at(0).should eq 0x001_u32
        replayer.bitmask_at(1).should eq 0x3ff_u32

        seen = [] of {UInt32, Int32}
        replayer.each_bitmask { |mask, frame| seen << {mask, frame} }
        seen.should eq [{0x001_u32, 0}, {0x3ff_u32, 1}]

        replayer.validate!(core)
      ensure
        core.destroy
      end
    end
  end

  it "counts mask lines when the header count is stale, and falls back to the .state naming convention" do
    with_tempdir do |dir|
      # What a crashed recorder leaves behind: placeholder frame_count,
      # no anchor_state line reached, unflushed tail lost.
      path = File.join(dir, "crashed.gir")
      File.write(path, <<-GIR)
        # GEMBA INPUT RECORDING v1
        # rom_checksum: 12345
        # game_code: AGBE
        # frame_count: 0000000000
        ---
        001
        002
        003
        GIR

      replayer = Gemba::InputReplayer.new(path)
      replayer.header_frame_count.should eq 0
      replayer.frame_count.should eq 3
      replayer.bitmask_at(2).should eq 0x003_u32
      replayer.anchor_state_path.should eq File.join(dir, "crashed.state")
    end
  end

  it "#validate! raises ChecksumMismatch against a different ROM" do
    with_tempdir do |dir|
      recorded_on = Gemba::Core.new(FILL_ROM)
      loaded = Gemba::Core.new(SPACE_BLAST_ROM)
      begin
        path = File.join(dir, "session.gir")
        recorder = Gemba::InputRecorder.new(path, recorded_on)
        recorder.start
        recorder.stop

        replayer = Gemba::InputReplayer.new(path)
        expect_raises(Gemba::InputReplayer::ChecksumMismatch, /checksum mismatch/) do
          replayer.validate!(loaded)
        end
        replayer.validate!(recorded_on)
      ensure
        recorded_on.destroy
        loaded.destroy
      end
    end
  end

  # The determinism-feeder use the format exists for: replaying the
  # recorded masks from the anchor state must land the emulator in the
  # exact same place the original session reached - asserted on pong's
  # known RAM (the Start press visibly advances title -> playing, so a
  # replay that dropped or misaligned input couldn't pass).
  it "replaying from the anchor state reproduces the recorded session's final state" do
    with_tempdir do |dir|
      path = File.join(dir, "pong.gir")
      start_mask = Gemba::Button::Start.value.to_u32

      original = Gemba::Core.new(PONG_ROM)
      recorder = Gemba::InputRecorder.new(path, original, rom_path: PONG_ROM)
      recorder.start
      5.times { record_frame(recorder, original, 0_u32) }
      3.times { record_frame(recorder, original, start_mask) }
      22.times { record_frame(recorder, original, 0_u32) }
      recorder.stop
      recorded_state = {original.bus_read32(PONG_BALL_X), original.bus_read32(PONG_BALL_Y),
                        original.bus_read32(PONG_STATE)}
      original.destroy

      recorded_state[2].should eq 1_u32 # the replayed Start press really advanced title -> playing

      replay = Gemba::Core.new(PONG_ROM)
      begin
        replayer = Gemba::InputReplayer.new(path)
        replayer.validate!(replay)
        replay.load_state_from_file(replayer.anchor_state_path).should be_true
        replayer.each_bitmask do |mask, _frame|
          replay.keys = mask
          replay.run_frame
        end

        {replay.bus_read32(PONG_BALL_X), replay.bus_read32(PONG_BALL_Y),
         replay.bus_read32(PONG_STATE)}.should eq recorded_state
      ensure
        replay.destroy
      end
    end
  end
end
