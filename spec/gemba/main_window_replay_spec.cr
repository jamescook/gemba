require "../spec_helper"
require "file_utils"

private FILL_ROM = File.join(__DIR__, "..", "fixtures", "fill.gba")

private def with_tempdir(&)
  dir = File.tempname("main_window_replay_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def record_gir(path : String, frames : Int32, rom_path : String = FILL_ROM) : Nil
  core = Gemba::Core.new(FILL_ROM)
  recorder = Gemba::InputRecorder.new(path, core, rom_path: rom_path)
  recorder.start
  frames.times do
    recorder.capture(0_u32)
    core.run_frame
  end
  recorder.stop
  core.destroy
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
  it "#open_replay plays a .gir to its end in the modal viewer; WM close stops the worker" do
    with_tempdir do |dir|
      gir = File.join(dir, "clip.gir")
      record_gir(gir, 10)
      window = new_window(dir)
      begin
        window.open_replay(gir)
        viewer = window.replay_window
        worker = viewer.worker.should_not be_nil

        window.app.interp.wait_until(10.seconds) { viewer.ended? }
        viewer.ended?.should be_true
        # Ended replays sit paused on the last frame, ruby-style.
        viewer.paused?.should be_true

        window.app.tcl_eval("eval [wm protocol #{viewer.handle.path} WM_DELETE_WINDOW]")
        window.app.interp.wait_until(5.seconds) { worker.done? }
        worker.done?.should be_true
        viewer.worker.should be_nil
      ensure
        window.destroy
      end
    end
  end

  it "a recording whose ROM has moved reports an error instead of opening" do
    with_tempdir do |dir|
      gir = File.join(dir, "orphan.gir")
      record_gir(gir, 2, rom_path: File.join(dir, "gone.gba"))
      window = new_window(dir)
      begin
        # ReplayWindow#open directly - MainWindow#open_replay would put
        # the same message in a blocking message_box.
        error = window.replay_window.open(gir)
        error.should_not be_nil
        error.to_s.should contain "no longer exists"
        window.replay_window.worker.should be_nil
      ensure
        window.destroy
      end
    end
  end
end
