require "../spec_helper"
require "file_utils"

private FILL_ROM        = File.join(__DIR__, "..", "fixtures", "fill.gba")
private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")

private def with_tempdir(&)
  dir = File.tempname("emulation_worker_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::EmulationWorker do
  it "delivers frame packets at native resolution and stops cleanly" do
    app = Tryst::App.new(title: "emulation_worker_spec_1")
    worker = Gemba::EmulationWorker.new(app, FILL_ROM)

    frames = [] of Gemba::EmulationWorker::FramePacket
    worker.on_frame { |packet| frames << packet }

    app.interp.wait_until(5.seconds) { frames.size >= 5 }
    frames.size.should be >= 5
    frames.first[:video].size.should eq 240 * 160

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    worker.done?.should be_true
    app.destroy
  end

  it "#pause halts delivery and #resume continues it" do
    app = Tryst::App.new(title: "emulation_worker_spec_2")
    worker = Gemba::EmulationWorker.new(app, FILL_ROM)

    count = 0
    worker.on_frame { count += 1 }

    app.interp.wait_until(5.seconds) { count >= 3 }
    worker.pause
    app.interp.wait_until(200.milliseconds) { false }
    paused_at = count
    10.times { app.update; sleep 20.milliseconds }
    (count - paused_at).should be <= 2

    worker.resume
    app.interp.wait_until(5.seconds) { count > paused_at + 5 }
    (count > paused_at).should be_true

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  # Turbo runs several emulated frames per real-time frame slot, but
  # mGBA generates audio at its own fixed rate regardless of how fast
  # it's stepped - queuing every turbo frame's audio would push several
  # times too much PCM into a fixed-rate stream every real second (an
  # actual desync, not just faster playback). Video still needs to be
  # full-rate for turbo to look right on screen.
  it "#turbo= keeps only a fraction of frames' audio, but every frame's video" do
    app = Tryst::App.new(title: "emulation_worker_spec_4")
    worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM)

    frames = [] of Gemba::EmulationWorker::FramePacket
    worker.on_frame { |packet| frames << packet }
    app.interp.wait_until(5.seconds) { frames.size >= 3 }

    worker.turbo = true
    frames.clear
    app.interp.wait_until(5.seconds) { frames.size >= 20 }
    worker.turbo = false

    frames.each(&.[:video].size.should(eq(240 * 160)))

    kept = frames.count { |packet| !packet[:audio].empty? }
    dropped = frames.count(&.[:audio].empty?)
    kept.should be > 0
    dropped.should be > 0
    (kept.to_f / frames.size).should be < 0.5

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  # Core's own core_spec.cr proves #rewind_append/#rewind_restore's
  # actual memory round-trip; this only exercises the cross-thread
  # message plumbing (#rewind=) - engaging and releasing it mid-stream
  # shouldn't crash the worker or stop frames from flowing.
  it "#rewind= toggles append/restore without crashing delivery" do
    app = Tryst::App.new(title: "emulation_worker_spec_rewind")
    worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM)

    frames = [] of Gemba::EmulationWorker::FramePacket
    worker.on_frame { |packet| frames << packet }
    app.interp.wait_until(5.seconds) { frames.size >= 5 }

    worker.rewind = true
    frames.clear
    app.interp.wait_until(5.seconds) { frames.size >= 10 }
    worker.rewind = false

    frames.clear
    app.interp.wait_until(5.seconds) { frames.size >= 5 }
    frames.each(&.[:video].size.should(eq(240 * 160)))

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  # Save/load happens on the worker thread (Core and SaveStateManager
  # live there exclusively); this exercises the cross-thread round trip.
  # state_dir_override isolates the test.
  it "#quick_save/#quick_load round-trip through the worker thread" do
    with_tempdir do |tmp|
      app = Tryst::App.new(title: "emulation_worker_spec_5")
      worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM, state_dir_override: tmp)

      messages = [] of String
      worker.on_message { |text| messages << text }
      frames = 0
      worker.on_frame { frames += 1 }

      app.interp.wait_until(5.seconds) { frames >= 3 }
      worker.quick_save
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("save_result:")) }
      messages.find(&.starts_with?("save_result:")).should eq "save_result:true:1:saved to slot 1"

      worker.quick_load
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("load_result:")) }
      messages.find(&.starts_with?("load_result:")).should eq "load_result:true:1:loaded slot 1"

      worker.stop
      app.interp.wait_until(5.seconds) { worker.done? }
      app.destroy
    end
  end

  it "quick_save_slot passed to the constructor reaches SaveStateManager" do
    with_tempdir do |tmp|
      app = Tryst::App.new(title: "emulation_worker_spec_6")
      worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM, state_dir_override: tmp, quick_save_slot: 3)

      messages = [] of String
      worker.on_message { |text| messages << text }
      frames = 0
      worker.on_frame { frames += 1 }

      app.interp.wait_until(5.seconds) { frames >= 3 }
      worker.quick_save
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("save_result:")) }
      messages.find(&.starts_with?("save_result:")).should eq "save_result:true:3:saved to slot 3"

      worker.stop
      app.interp.wait_until(5.seconds) { worker.done? }
      app.destroy
    end
  end

  it "#save_slot/#load_slot round-trip an explicit slot, independent of quick_save_slot" do
    with_tempdir do |tmp|
      app = Tryst::App.new(title: "emulation_worker_spec_7")
      worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM, state_dir_override: tmp)

      messages = [] of String
      worker.on_message { |text| messages << text }
      frames = 0
      worker.on_frame { frames += 1 }

      app.interp.wait_until(5.seconds) { frames >= 3 }
      worker.save_slot(7)
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("save_result:")) }
      messages.find(&.starts_with?("save_result:")).should eq "save_result:true:7:saved to slot 7"

      worker.load_slot(7)
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("load_result:")) }
      messages.find(&.starts_with?("load_result:")).should eq "load_result:true:7:loaded slot 7"

      worker.stop
      app.interp.wait_until(5.seconds) { worker.done? }
      app.destroy
    end
  end

  # The whole message round-trip for a .gir recording: start (which
  # creates the directory and the anchor state on the worker thread,
  # where Core lives), masks captured per frame as they're applied,
  # stop finalizing the header. InputRecorder's own spec covers the
  # file format; this is the cross-thread plumbing.
  it "records the masks frames actually ran under via #start_input_recording/#stop_input_recording" do
    with_tempdir do |tmp|
      app = Tryst::App.new(title: "emulation_worker_spec_gir")
      worker = Gemba::EmulationWorker.new(app, FILL_ROM)

      messages = [] of String
      worker.on_message { |text| messages << text }
      frames = 0
      worker.on_frame { frames += 1 }

      # A nested, not-yet-existing directory - start is what creates it.
      path = File.join(tmp, "recordings", "session.gir")
      worker.start_input_recording(path)
      app.interp.wait_until(5.seconds) { messages.includes?("input_record_result:start:true") }

      worker.input_mask = 0x041_u32
      baseline = frames
      app.interp.wait_until(5.seconds) { frames >= baseline + 10 }
      worker.stop_input_recording
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("input_record_result:stop:")) }

      reported = messages.find!(&.starts_with?("input_record_result:stop:"))
        .lchop("input_record_result:stop:").to_i
      reported.should be > 0

      replayer = Gemba::InputReplayer.new(path)
      replayer.frame_count.should eq reported
      replayer.header_frame_count.should eq reported
      replayer.rom_checksum.should_not be_nil
      File.exists?(replayer.anchor_state_path).should be_true

      # The mask sent mid-recording shows up in the recorded stream.
      masks = [] of UInt32
      replayer.each_bitmask { |mask, _frame| masks << mask }
      masks.should contain 0x041_u32

      worker.stop
      app.interp.wait_until(5.seconds) { worker.done? }
      app.destroy
    end
  end

  # .grec's worker-side twin of the .gir test above: recorder_spec.cr
  # proves the byte format, this proves the cross-thread plumbing and
  # that real emulator frames land in the file.
  it "records video+audio to a .grec via #start_recording/#stop_recording" do
    with_tempdir do |tmp|
      app = Tryst::App.new(title: "emulation_worker_spec_grec")
      worker = Gemba::EmulationWorker.new(app, FILL_ROM)

      messages = [] of String
      worker.on_message { |text| messages << text }
      frames = 0
      worker.on_frame { frames += 1 }

      path = File.join(tmp, "captures", "clip.grec")
      worker.start_recording(path)
      app.interp.wait_until(5.seconds) { messages.includes?("record_result:start:true") }

      baseline = frames
      app.interp.wait_until(5.seconds) { frames >= baseline + 10 }
      worker.stop_recording
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("record_result:stop:")) }

      reported = messages.find!(&.starts_with?("record_result:stop:"))
        .lchop("record_result:stop:").to_i
      reported.should be > 0

      File.open(path, "rb") do |io|
        magic = Bytes.new(8)
        io.read_fully(magic)
        String.new(magic).should eq "GEMBAREC"
        io.read_byte.should eq 1_u8
        io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).should eq 240_u16
        io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).should eq 160_u16
      end
      # Footer carries the same count the stop result reported.
      File.open(path, "rb") do |io|
        io.seek(-8, IO::Seek::End)
        io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).should eq reported.to_u32
        tail = Bytes.new(4)
        io.read_fully(tail)
        String.new(tail).should eq "GEND"
      end

      worker.stop
      app.interp.wait_until(5.seconds) { worker.done? }
      app.destroy
    end
  end

  # Replay mode: the worker takes its masks from a .gir instead of the
  # "mask:" channel, plays exactly the recorded frames from the anchor
  # state, reports replay_ended once, then idles rather than emulating
  # on with no input.
  it "replay_gir plays a recording's frames then idles with one replay_ended" do
    with_tempdir do |tmp|
      gir = File.join(tmp, "session.gir")
      core = Gemba::Core.new(FILL_ROM)
      recorder = Gemba::InputRecorder.new(gir, core, rom_path: FILL_ROM)
      recorder.start
      8.times do |i|
        mask = (i % 4).to_u32
        recorder.capture(mask)
        core.keys = mask
        core.run_frame
      end
      recorder.stop
      core.destroy

      app = Tryst::App.new(title: "emulation_worker_spec_replay")
      worker = Gemba::EmulationWorker.new(app, FILL_ROM, replay_gir: gir)
      messages = [] of String
      frames = 0
      worker.on_message { |text| messages << text }
      worker.on_frame do |packet|
        frames += 1
        worker.release_frame(packet[:frame_num])
      end

      app.interp.wait_until(10.seconds) { messages.includes?("replay_ended:8") }
      messages.count("replay_ended:8").should eq 1
      frames.should eq 8

      # Past the end: no further frames arrive.
      app.interp.wait_until(500.milliseconds) { false }
      frames.should eq 8

      worker.stop
      app.interp.wait_until(5.seconds) { worker.done? }
      app.destroy
    end
  end

  it "replay mode refuses a recording from a different ROM through on_error" do
    with_tempdir do |tmp|
      gir = File.join(tmp, "session.gir")
      core = Gemba::Core.new(FILL_ROM)
      recorder = Gemba::InputRecorder.new(gir, core, rom_path: FILL_ROM)
      recorder.start
      recorder.stop
      core.destroy

      app = Tryst::App.new(title: "emulation_worker_spec_replay_bad")
      worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM, replay_gir: gir)
      error = nil
      worker.on_error { |text| error = text }

      app.interp.wait_until(10.seconds) { !error.nil? }
      error.to_s.should contain "ChecksumMismatch"

      worker.stop
      app.destroy
    end
  end

  # The correctness property FrameRing exists to guarantee: a packet the
  # main thread is still holding must never have its buffer contents
  # change out from under it, even once the worker has produced far more
  # frames than the ring has slots for. Deliberately never calls
  # #release_frame for the held packet - the scenario a stalled/slow UI
  # thread would produce - so this only passes if the ring genuinely
  # refuses to reuse a slot that's still owned, falling back to a fresh
  # allocation for later frames instead of tearing this one.
  it "a delivered packet's video buffer is never mutated by a later frame while still held" do
    app = Tryst::App.new(title: "emulation_worker_spec_ring_tearing")
    worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM)

    frames = [] of Gemba::EmulationWorker::FramePacket
    worker.on_frame { |packet| frames << packet }
    app.interp.wait_until(5.seconds) { frames.size >= 3 }

    held = frames.first
    snapshot = held[:video].dup

    # Comfortably more than EmulationWorker::RING_SIZE, to force real
    # slot-reuse pressure while `held` is still outstanding.
    app.interp.wait_until(5.seconds) { frames.size >= 40 }

    held[:video].should eq snapshot

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  # The intended steady-state path: the consumer releases each frame
  # right after using it (mirroring EmulatorFrame#on_frame), so the ring
  # rotates indefinitely rather than permanently falling back to
  # allocation once RING_SIZE frames have been produced.
  it "releasing each frame lets delivery continue well past the ring's own size" do
    app = Tryst::App.new(title: "emulation_worker_spec_ring_rotation")
    worker = Gemba::EmulationWorker.new(app, SPACE_BLAST_ROM)

    delivered = 0
    worker.on_frame do |packet|
      delivered += 1
      packet[:video].size.should eq 240 * 160
      worker.release_frame(packet[:frame_num])
    end

    app.interp.wait_until(5.seconds) { delivered >= 60 }
    delivered.should be >= 60

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  it "reports a bad ROM path through on_error rather than crashing the app" do
    app = Tryst::App.new(title: "emulation_worker_spec_3")
    worker = Gemba::EmulationWorker.new(app, "/nonexistent/path.gba")

    error = nil
    worker.on_error { |text| error = text }

    app.interp.wait_until(5.seconds) { !error.nil? }
    error.should_not be_nil
    error.to_s.should contain "ArgumentError"

    app.destroy
  end
end

describe "rich presence" do
  it "evaluates the activated script against real emulator memory and reports it back" do
    app = Tryst::App.new(title: "emulation_worker_spec_rp")
    worker = Gemba::EmulationWorker.new(app, FILL_ROM)

    messages = [] of String
    worker.on_message { |text| messages << text }

    # @Number(0xH0000) reads RA address 0, i.e. the first byte of IWRAM -
    # a real bus read through the peek callback, not a stub.
    worker.activate_rich_presence("Display:\nIWRAM0 @Number(0xH0000)")

    presence = nil
    app.interp.wait_until(15.seconds) do
      presence = messages.find(&.starts_with?("rich_presence:"))
      !presence.nil?
    end

    delivered = presence.should_not be_nil
    delivered.should start_with "rich_presence:IWRAM0 "

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  it "sends nothing while no script is active" do
    app = Tryst::App.new(title: "emulation_worker_spec_rp_off")
    worker = Gemba::EmulationWorker.new(app, FILL_ROM)

    messages = [] of String
    worker.on_message { |text| messages << text }

    frames = 0
    worker.on_frame { frames += 1 }
    app.interp.wait_until(15.seconds) { frames >= Gemba::EmulationWorker::RP_EVAL_INTERVAL + 5 }

    messages.any?(&.starts_with?("rich_presence:")).should be_false

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end
end

private def achievement(id : UInt32, memaddr : String) : Gemba::Achievements::Achievement
  Gemba::Achievements::Achievement.new(id: id, title: "Achievement #{id}", description: "", points: 5,
    memaddr: memaddr, flags: Gemba::Achievements::Achievement::CORE)
end

describe "achievements" do
  # A hit-count target (see ra_runtime_spec's own note on WAITING) so
  # the condition is met after a known number of frames regardless of
  # what the ROM keeps at that address.
  it "reports an activated achievement's id once its condition is met, and only once" do
    app = Tryst::App.new(title: "emulation_worker_spec_ach")
    worker = Gemba::EmulationWorker.new(app, FILL_ROM)

    messages = [] of String
    worker.on_message { |text| messages << text }
    frames = 0
    worker.on_frame { frames += 1 }

    worker.activate_achievements([achievement(9_u32, "0xH0000>=0.30.")])

    app.interp.wait_until(15.seconds) { messages.includes?("achievement_unlocked:9") }

    # Keep emulating well past the trigger: a triggered achievement
    # stays triggered in rcheevos, it does not fire every frame after.
    seen_at = frames
    app.interp.wait_until(15.seconds) { frames >= seen_at + 60 }
    messages.count("achievement_unlocked:9").should eq 1

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  it "reports a condition rcheevos rejects rather than dying on it, and keeps the rest" do
    app = Tryst::App.new(title: "emulation_worker_spec_ach_bad")
    worker = Gemba::EmulationWorker.new(app, FILL_ROM)

    messages = [] of String
    worker.on_message { |text| messages << text }

    worker.activate_achievements([achievement(5_u32, "not a valid condition ((("), achievement(6_u32, "0xH0000>=0.3.")])

    app.interp.wait_until(15.seconds) { messages.includes?("achievement_unlocked:6") }
    rejected = messages.find(&.starts_with?("achievement_rejected:5:")).should_not be_nil
    rejected.should contain "rcheevos rejected"
    messages.should_not contain "achievement_unlocked:5"

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end

  it "keeps evaluating a presence script for a game with no achievements at all" do
    app = Tryst::App.new(title: "emulation_worker_spec_ach_rp_only")
    worker = Gemba::EmulationWorker.new(app, FILL_ROM)

    messages = [] of String
    worker.on_message { |text| messages << text }
    worker.activate_rich_presence("Display:\nIWRAM0 @Number(0xH0000)")

    app.interp.wait_until(15.seconds) { messages.any?(&.starts_with?("rich_presence:")) }
    messages.none?(&.starts_with?("achievement_unlocked:")).should be_true

    worker.stop
    app.interp.wait_until(5.seconds) { worker.done? }
    app.destroy
  end
end

describe "achievements across a save-state load" do
  # Memory just jumped to an arbitrary saved state, so every achievement
  # goes back through rcheevos' priming - including its hit count. A
  # 120-frame target started before the save and loaded at ~frame 60
  # must arrive ~120 frames AFTER the load, not ~60: without the reset
  # the count would simply carry on and fire early.
  it "restarts an achievement's progress when a state is loaded" do
    with_tempdir do |tmp|
      app = Tryst::App.new(title: "emulation_worker_spec_ach_load")
      worker = Gemba::EmulationWorker.new(app, FILL_ROM, state_dir_override: tmp)

      messages = [] of String
      worker.on_message { |text| messages << text }
      frames = 0
      worker.on_frame { frames += 1 }

      worker.activate_achievements([achievement(3_u32, "0xH0000>=0.120.")])
      app.interp.wait_until(5.seconds) { frames >= 3 }
      worker.quick_save
      app.interp.wait_until(5.seconds) { messages.any?(&.starts_with?("save_result:true")) }

      app.interp.wait_until(10.seconds) { frames >= 60 }
      worker.quick_load
      loaded_at = nil
      app.interp.wait_until(5.seconds) do
        loaded_at ||= frames if messages.any?(&.starts_with?("load_result:true"))
        !loaded_at.nil?
      end
      messages.should_not contain "achievement_unlocked:3"

      unlocked_at = nil
      app.interp.wait_until(15.seconds) do
        unlocked_at ||= frames if messages.includes?("achievement_unlocked:3")
        !unlocked_at.nil?
      end

      # Frame counts are observed from the main thread, so allow slack
      # either side - the point is "about 120 after the load", never
      # "about 60".
      (unlocked_at.should_not(be_nil) - loaded_at.should_not(be_nil)).should be >= 100
      messages.count("achievement_unlocked:3").should eq 1

      worker.stop
      app.interp.wait_until(5.seconds) { worker.done? }
      app.destroy
    end
  end
end
