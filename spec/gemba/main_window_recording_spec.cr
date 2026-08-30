require "../spec_helper"
require "file_utils"

private FILL_ROM = File.join(__DIR__, "..", "fixtures", "fill.gba")

private def with_tempdir(&)
  dir = File.tempname("main_window_recording_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::MainWindow do
  # The .gir wiring next door (main_window_input_recording_spec) covers
  # the shared worker-teardown path; this covers .grec's own hotkey,
  # menu item, dot and file.
  it "F10 starts and stops a .grec capture: flag, HUD dot, menu item, file on disk" do
    with_tempdir do |dir|
      window = Gemba::MainWindow.new(
        rom_library_path: File.join(dir, "rom_library.json"),
        config_path: File.join(dir, "settings.json"),
        gamepad_polling: false,
        recordings_dir: File.join(dir, "recordings"),
      )
      begin
        item = window.record_item.should_not be_nil
        item.options["state"].should eq "disabled"

        window.load_rom(FILL_ROM)
        frame = window.emulator_frame.should_not be_nil
        item.options["state"].should eq "normal"
        item.options["label"].should eq "Start Capture"
        frame.recording?.should be_false

        window.app.tcl_eval("event generate . <F10>")
        window.app.interp.wait_until(5.seconds) { frame.recording? }
        window.video.recording_dot?.should be_true
        item.options["label"].should eq "Stop Capture"

        # Let real frames land in the file before stopping.
        start = Time.instant
        window.app.interp.wait_until(2.seconds) { (Time.instant - start) > 300.milliseconds }

        window.app.tcl_eval("event generate . <F10>")
        window.app.interp.wait_until(5.seconds) { !frame.recording? }
        window.video.recording_dot?.should be_false
        item.options["label"].should eq "Start Capture"

        grecs = Dir.glob(File.join(dir, "recordings", "*.grec"))
        grecs.size.should eq 1
        File.open(grecs.first, "rb") do |io|
          magic = Bytes.new(8)
          io.read_fully(magic)
          String.new(magic).should eq "GEMBAREC"
          io.seek(-8, IO::Seek::End)
          io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).should be > 0_u32
          tail = Bytes.new(4)
          io.read_fully(tail)
          String.new(tail).should eq "GEND"
        end
      ensure
        window.destroy
      end
    end
  end
end
