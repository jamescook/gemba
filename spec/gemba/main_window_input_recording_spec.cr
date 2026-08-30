require "../spec_helper"
require "file_utils"

private FILL_ROM = File.join(__DIR__, "..", "fixtures", "fill.gba")

private def with_tempdir(&)
  dir = File.tempname("main_window_input_recording_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def new_window(dir : String) : Gemba::MainWindow
  Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: false,
    recordings_dir: File.join(dir, "recordings"),
  )
end

describe Gemba::MainWindow do
  describe "input recording" do
    it "F4 starts and stops a .gir recording: flag, HUD dot, menu item, file on disk" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          item = window.input_record_item.should_not be_nil
          item.options["state"].should eq "disabled"

          window.load_rom(FILL_ROM)
          frame = window.emulator_frame.should_not be_nil
          item.options["state"].should eq "normal"
          item.options["label"].should eq "Start Recording Inputs"
          frame.input_recording?.should be_false

          window.app.tcl_eval("event generate . <F4>")
          window.app.interp.wait_until(5.seconds) { frame.input_recording? }
          window.video.input_recording_dot?.should be_true
          item.options["label"].should eq "Stop Recording Inputs"

          window.app.tcl_eval("event generate . <F4>")
          window.app.interp.wait_until(5.seconds) { !frame.input_recording? }
          window.video.input_recording_dot?.should be_false
          item.options["label"].should eq "Start Recording Inputs"

          girs = Dir.glob(File.join(dir, "recordings", "*.gir"))
          girs.size.should eq 1
          replayer = Gemba::InputReplayer.new(girs.first)
          replayer.frame_count.should eq replayer.header_frame_count
          File.exists?(replayer.anchor_state_path).should be_true
        ensure
          window.app.destroy
        end
      end
    end

    it "swapping ROMs mid-recording finalizes the file and resets the dot and menu label" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          window.load_rom(FILL_ROM)
          frame = window.emulator_frame.should_not be_nil
          window.toggle_input_recording
          window.app.interp.wait_until(5.seconds) { frame.input_recording? }
          # Let some frames actually get captured before the swap.
          old_worker = frame.worker
          start = Time.instant
          window.app.interp.wait_until(2.seconds) { (Time.instant - start) > 300.milliseconds }

          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(5.seconds) { old_worker.done? }

          # The fresh session starts un-recording everywhere...
          window.emulator_frame.should_not(be_nil).input_recording?.should be_false
          window.video.input_recording_dot?.should be_false
          window.input_record_item.should_not(be_nil).options["label"].should eq "Start Recording Inputs"

          # ...and the interrupted recording was finalized on the old
          # worker's way out (header rewritten, tail flushed), not left
          # truncated with a zero count.
          girs = Dir.glob(File.join(dir, "recordings", "*.gir"))
          girs.size.should eq 1
          replayer = Gemba::InputReplayer.new(girs.first)
          replayer.frame_count.should be > 0
          replayer.header_frame_count.should eq replayer.frame_count
        ensure
          window.app.destroy
        end
      end
    end
  end
end
