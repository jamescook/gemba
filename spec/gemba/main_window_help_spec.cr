require "../spec_helper"
require "file_utils"

private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")

private def with_tempdir(&)
  dir = File.tempname("main_window_help_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# focus_probe pinned to "focused": on a real desktop the panel takes
# window-manager focus when shown, which would otherwise trip the
# focus-loss auto-pause on top of the one under test.
private def new_window(dir : String) : Gemba::MainWindow
  Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: false,
    focus_probe: -> { true },
  )
end

private def running_frame(window : Gemba::MainWindow) : Gemba::EmulatorFrame
  window.load_rom(SPACE_BLAST_ROM)
  window.app.interp.wait_until(5.seconds) { !window.video.last_frame_argb.nil? }
  window.emulator_frame || raise "expected an emulator frame after load_rom"
end

# See main_window_auto_pause_spec's note: the worker must be awaited
# before the app goes away underneath it.
private def stop_and_destroy(window : Gemba::MainWindow) : Nil
  if worker = window.worker
    worker.stop
    window.app.interp.wait_until(5.seconds) { worker.done? }
  end
  window.app.destroy
end

private def press_question(window : Gemba::MainWindow) : Nil
  window.app.tcl_eval("event generate . <question>")
  window.app.update
end

describe Gemba::MainWindow do
  describe "hotkey reference panel" do
    it "'?' opens the panel and pauses the game; '?' again closes it and resumes" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          frame = running_frame(window)
          frame.paused?.should be_false

          press_question(window)
          window.help_window.visible?.should be_true
          window.auto_pause.held?(:help).should be_true
          frame.paused?.should be_true
          window.help_window.key_text(:pause).should eq "p"

          press_question(window)
          window.help_window.visible?.should be_false
          window.auto_pause.held?(:help).should be_false
          frame.paused?.should be_false
        ensure
          stop_and_destroy(window)
        end
      end
    end

    it "closing the panel over a game the user had paused leaves it paused" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          frame = running_frame(window)
          frame.pause
          frame.paused?.should be_true

          window.toggle_help
          window.help_window.visible?.should be_true
          window.toggle_help
          window.help_window.visible?.should be_false
          frame.paused?.should be_true
        ensure
          stop_and_destroy(window)
        end
      end
    end

    it "doesn't open under a modal, and the WM close button releases the pause like '?' does" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          frame = running_frame(window)

          window.show_settings
          window.toggle_help
          window.help_window.visible?.should be_false
          window.modal_stack.pop
          window.app.update

          window.toggle_help
          frame.paused?.should be_true
          window.app.tcl_eval("eval [wm protocol #{window.help_window.handle.path} WM_DELETE_WINDOW]")
          window.app.update
          window.help_window.visible?.should be_false
          frame.paused?.should be_false
        ensure
          stop_and_destroy(window)
        end
      end
    end
  end
end
