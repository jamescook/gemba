require "../spec_helper"
require "file_utils"

private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")

private def with_tempdir(&)
  dir = File.tempname("main_window_auto_pause_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# SDL's real input-focus flag can't be steered headlessly - and reads
# false forever under Xvfb, since X11 hands SDL a child window that
# never takes X focus - so the focus examples drive MainWindow's probe
# seam instead, the same one ra_requester: is.
private def new_window(dir : String, focus_probe : Proc(Bool)? = nil) : Gemba::MainWindow
  Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: false,
    focus_probe: focus_probe,
  )
end

private def running_frame(window : Gemba::MainWindow) : Gemba::EmulatorFrame
  window.load_rom(SPACE_BLAST_ROM)
  window.app.interp.wait_until(5.seconds) { !window.video.last_frame_argb.nil? }
  frame = window.emulator_frame
  raise "expected an emulator frame after load_rom" unless frame
  frame
end

describe Gemba::MainWindow do
  describe "auto-pause on focus loss" do
    it "pauses while the app is unfocused and resumes when focus comes back" do
      with_tempdir do |dir|
        focused = true
        window = new_window(dir, -> { focused })
        begin
          frame = running_frame(window)
          frame.paused?.should be_false

          focused = false
          window.app.interp.wait_until(5.seconds) { frame.paused? }
          window.auto_pause.held?(:focus_loss).should be_true

          focused = true
          window.app.interp.wait_until(5.seconds) { !frame.paused? }
          window.auto_pause.active?.should be_false
        ensure
          window.worker.try(&.stop)
          window.app.destroy
        end
      end
    end

    it "leaves the game running when the setting is off" do
      with_tempdir do |dir|
        focused = true
        window = new_window(dir, -> { focused })
        begin
          window.config.pause_on_focus_loss = false
          frame = running_frame(window)

          focused = false
          sleep 700.milliseconds # several poll intervals
          window.app.update

          frame.paused?.should be_false
          window.auto_pause.active?.should be_false
        ensure
          window.worker.try(&.stop)
          window.app.destroy
        end
      end
    end

    # The latch: on X11 the flag never goes true, and pausing on a
    # signal that can never clear would strand the game paused.
    it "stays out of the way entirely on a platform that never reports focus" do
      with_tempdir do |dir|
        window = new_window(dir, -> { false })
        begin
          frame = running_frame(window)

          sleep 700.milliseconds
          window.app.update

          frame.paused?.should be_false
          window.auto_pause.active?.should be_false
        ensure
          window.worker.try(&.stop)
          window.app.destroy
        end
      end
    end

    it "coming back to a still-open modal doesn't resume behind it" do
      with_tempdir do |dir|
        focused = true
        window = new_window(dir, -> { focused })
        begin
          frame = running_frame(window)

          window.show_settings
          frame.paused?.should be_true

          focused = false
          window.app.interp.wait_until(5.seconds) { window.auto_pause.held?(:focus_loss) }
          focused = true
          window.app.interp.wait_until(5.seconds) { !window.auto_pause.held?(:focus_loss) }

          # Settings is still up, so the game stays paused.
          frame.paused?.should be_true
          window.auto_pause.held?(:modal).should be_true

          window.modal_stack.pop
          frame.paused?.should be_false
        ensure
          window.worker.try(&.stop)
          window.app.destroy
        end
      end
    end

    it "never resumes a game the user had paused before switching away" do
      with_tempdir do |dir|
        focused = true
        window = new_window(dir, -> { focused })
        begin
          frame = running_frame(window)
          frame.pause
          frame.paused?.should be_true

          focused = false
          window.app.interp.wait_until(5.seconds) { window.auto_pause.held?(:focus_loss) }
          focused = true
          window.app.interp.wait_until(5.seconds) { !window.auto_pause.held?(:focus_loss) }

          frame.paused?.should be_true
        ensure
          window.worker.try(&.stop)
          window.app.destroy
        end
      end
    end
  end

  describe "auto-pause while a menu is posted" do
    # No ROM loaded: what's under test is the hold/release bookkeeping
    # and the poll that drives it, not the emulator. A real posted menu
    # can't be simulated headlessly - on macOS it's a native NSMenu,
    # and posting one anywhere blocks on user input (see spec_helper's
    # own stub_tk_popup) - so this drives the same two signals Tk
    # itself does: the <<MenuSelect>> the menu bar gets when a cascade
    # opens, and the active entry being cleared when tracking ends.
    it "holds while a cascade is active and releases once the bar goes idle" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          app = window.app
          bar = app.tcl_eval(". cget -menu")
          bar.should_not be_empty

          app.tcl_eval("#{bar} activate 0")
          app.tcl_eval("event generate #{bar} <<MenuSelect>>")
          app.update
          window.auto_pause.held?(:menu).should be_true

          app.tcl_eval("#{bar} activate none")
          # Nothing tells us the menu closed on macOS, so the release is
          # the poll noticing the bar has no active entry left.
          app.interp.wait_until(5.seconds) { !window.auto_pause.held?(:menu) }
          window.auto_pause.active?.should be_false
        ensure
          window.app.destroy
        end
      end
    end
  end
end
