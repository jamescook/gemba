require "../spec_helper"
require "file_utils"

private FILL_ROM        = File.join(__DIR__, "..", "fixtures", "fill.gba")
private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")

# pong's known RAM layout (see core_spec.cr) - what lets the headless
# test prove the recorded input actually drove the emulator, not just
# that frames ran.
private PONG_ROM   = File.join(__DIR__, "..", "fixtures", "pong.gba")
private PONG_STATE = 0x03000028_u32

private def with_tempdir(&)
  dir = File.tempname("cli_replay_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def record_gir(path : String, rom : String, masks : Array(UInt32)) : Nil
  core = Gemba::Core.new(rom)
  recorder = Gemba::InputRecorder.new(path, core, rom_path: rom)
  recorder.start
  masks.each do |mask|
    recorder.capture(mask)
    core.keys = mask
    core.run_frame
  end
  recorder.stop
  core.destroy
end

describe Gemba::CLI::Replay do
  it "parses flags and positionals into a typed plan (dry run)" do
    plan = Gemba::CLI.run(
      ["replay", "--headless", "--progress", "clip.gir", "override.gba"],
      dry_run: true).as(Gemba::CLI::Replay::Plan)
    plan.headless.should be_true
    plan.progress.should be_true
    plan.gir.to_s.should end_with "/clip.gir"
    plan.rom.to_s.should end_with "/override.gba"
    plan.error.should be_nil

    Gemba::CLI.run(["replay", "-l"], dry_run: true).as(Gemba::CLI::Replay::Plan).list.should be_true
    Gemba::CLI.run(["replay"], dry_run: true).as(Gemba::CLI::Replay::Plan)
      .error.to_s.should contain "requires a .gir file"
  end

  it "raises CLI::Error (the exit-1 path) when no .gir is given for real" do
    expect_raises(Gemba::CLI::Error, /requires a .gir file/) do
      Gemba::CLI.run(["replay", "--headless"], io: IO::Memory.new)
    end
  end

  # The whole point of the format: the same InputReplayer drive that the
  # in-app viewer's worker uses, headless. The Start press recorded on
  # pong's title screen must land the replayed core on state 1
  # (playing) - a replay that dropped or misaligned input could not.
  it "--headless replays the recording against the header's ROM and reports the frame count" do
    with_tempdir do |dir|
      gir = File.join(dir, "session.gir")
      start_mask = Gemba::Button::Start.value.to_u32
      masks = Array(UInt32).new(5, 0_u32) + Array(UInt32).new(3, start_mask) + Array(UInt32).new(22, 0_u32)
      record_gir(gir, PONG_ROM, masks)

      # Prove the recording itself reaches "playing" so the CLI run
      # below is asserting something real.
      probe = Gemba::Core.new(PONG_ROM)
      replayer = Gemba::InputReplayer.new(gir)
      probe.load_state_from_file(replayer.anchor_state_path).should be_true
      replayer.each_bitmask do |mask, _idx|
        probe.keys = mask
        probe.run_frame
      end
      probe.bus_read32(PONG_STATE).should eq 1_u32
      probe.destroy

      io = IO::Memory.new
      plan = Gemba::CLI.run(["replay", "--headless", gir], io: io).as(Gemba::CLI::Replay::Plan)
      plan.headless.should be_true
      io.to_s.should eq "Replayed #{gir} (30 frames)\n"
    end
  end

  it "--headless with a ROM override validates the checksum and refuses a mismatch" do
    with_tempdir do |dir|
      gir = File.join(dir, "session.gir")
      record_gir(gir, FILL_ROM, [0_u32, 0_u32])

      expect_raises(Gemba::CLI::Error, /checksum mismatch/) do
        Gemba::CLI.run(["replay", "--headless", gir, SPACE_BLAST_ROM], io: IO::Memory.new)
      end
    end
  end

  it "-l lists recordings grouped by game code" do
    with_tempdir do |dir|
      recordings = File.join(dir, "recordings")
      io = IO::Memory.new
      Gemba::CLI.run(["replay", "-l"], io: io, recordings_dir: recordings)
      io.to_s.should contain "No recordings directory found"

      Dir.mkdir_p(recordings)
      record_gir(File.join(recordings, "a.gir"), FILL_ROM, [0_u32] * 3)
      io = IO::Memory.new
      Gemba::CLI.run(["replay", "-l"], io: io, recordings_dir: recordings)
      output = io.to_s
      output.should contain "AGB-BFIL:" # fill.gba's game-code header line
      output.should contain "a.gir  (3 frames)"
    end
  end
end
