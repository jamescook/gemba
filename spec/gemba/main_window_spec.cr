require "../spec_helper"
require "file_utils"

private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")
private FILL_ROM        = File.join(__DIR__, "..", "fixtures", "fill.gba")

private def with_tempdir(&)
  dir = File.tempname("main_window_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Runs whatever script is bound to path/event directly - see
# save_state_picker_spec.cr's own note on why (a synthetic `event
# generate` doesn't reliably reach a classic Tk widget's own instance
# binding in this environment, even once shown).
private def invoke_binding(app : Tryst::App, path : String, event : String) : Nil
  script = app.tcl_eval("bind #{path} #{event}")
  app.tcl_eval(script) unless script.empty?
end

# rom_library_path/config_path keep every real ROM load in these specs
# out of the real ~/Library/Application Support/gemba data - see
# MainWindow's own doc comment on why those two (unlike screenshots
# below) need an override rather than after-the-fact cleanup: a written
# rom_library.json/settings.json could otherwise shadow the user's own.
#
# gamepad_polling: false - none of these specs exercise gamepad hot-plug
# (see main_window_gamepad_spec.cr for the ones that do); leaving it on
# would register this window's Tryst::SDL::Gamepad.on_added/on_removed
# callbacks anyway (a process-wide singleton, not per-instance - see
# MainWindow's own doc comment), left dangling against a destroyed
# window the moment some OTHER spec's .poll_events call fires them.
private def new_window(dir : String) : Gemba::MainWindow
  Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: false,
  )
end

describe Gemba::MainWindow do
  # MainWindow always constructs a real AudioOutput. spec_helper.cr
  # forces SDL's "dummy" audio driver, so that always opens successfully
  # and tracks real queued bytes here, same as tryst-sdl's own suite -
  # nothing below depends on the actual host having audio hardware.

  # Pixel-level correctness of what VideoOutput draws is already
  # covered by video_output_spec.cr's own #draw-based check (reading
  # back right after a real #present is unreliable - SDL
  # double-buffers, so a read-back racing an actively-running frame
  # loop can see the OTHER, not-yet-drawn-into buffer). This spec's own
  # job is the WIRING: does load_rom actually connect EmulationWorker
  # -> VideoOutput/AudioOutput without crashing, and keep producing
  # real output.
  it "loads a ROM and drives real video and audio output end to end" do
    with_tempdir do |dir|
      window = new_window(dir)
      window.load_rom(SPACE_BLAST_ROM)

      window.app.interp.wait_until(5.seconds) { window.audio.fill_ratio > 0.0 }
      window.audio.fill_ratio.should be > 0.0

      worker = window.worker
      raise "expected a worker after load_rom" unless worker
      worker.done?.should be_false

      worker.stop
      window.destroy
    end
  end

  it "patches rom_id/game_code onto the RomLibrary entry once the worker reports the loaded ROM back" do
    with_tempdir do |dir|
      rom_library_path = File.join(dir, "rom_library.json")
      window = Gemba::MainWindow.new(rom_library_path: rom_library_path, config_path: File.join(dir, "settings.json"),
        gamepad_polling: false)
      begin
        window.load_rom(SPACE_BLAST_ROM)

        # rom_id/game_code arrive asynchronously once EmulationWorker
        # reports back - see MainWindow#update_rom_identity. Poll the
        # in-memory #rom_info rather than re-reading rom_library.json;
        # File I/O in a tight polling loop crashes the syscall guard's
        # backtrace capture under GC pressure.
        window.app.interp.wait_until(5.seconds) { !window.emulator_frame.try(&.rom_info).nil? }

        entry = Gemba::RomLibrary.new(rom_library_path).all.first
        entry.path.should eq SPACE_BLAST_ROM
        entry.game_code.should_not be_empty
        entry.rom_id.should start_with("#{entry.game_code}-")
        entry.rom_id[(entry.game_code.size + 1)..].should match(/\A[0-9A-F]{8}\z/)

        window.worker.try(&.stop)
      ensure
        window.destroy
      end
    end
  end

  it "each Settings menu item opens the settings window straight on its own tab" do
    with_tempdir do |dir|
      window = new_window(dir)

      # Invoked the way a real menu click does, by entry label - what's
      # under test is the wiring from menu item to pre-selected tab, so
      # calling #show_settings directly would prove nothing.
      menu = window.app.tcl_eval(". cget -menu")
      settings_menu = window.app.tcl_eval("#{menu} entrycget Settings -menu")

      {"General" => :general, "Video" => :video, "Audio" => :audio,
       "Gameplay" => :gameplay, "Gamepad" => :gamepad, "Achievements" => :achievements}.each do |label, tab|
        window.app.tcl_eval("#{settings_menu} invoke #{label}")
        window.settings_window.selected_tab.should eq tab
        window.modal_stack.pop
      end

      window.destroy
    end
  end

  it "settings can be reopened after being closed via the OS close button" do
    with_tempdir do |dir|
      window = new_window(dir)
      path = window.settings_window.handle.path

      window.show_settings
      window.modal_stack.active?.should be_true

      # Simulates the window manager sending WM_DELETE_WINDOW, the same
      # script Tk itself would re-invoke when the user clicks the real
      # close button - not ModalStack#pop directly, since the actual bug
      # this guards against was MainWindow never wiring the close button
      # to anything at all (Tk's own default then applies: destroy the
      # toplevel outright, and this stack never learns it happened).
      close_script = window.app.tcl_invoke("wm", "protocol", path, "WM_DELETE_WINDOW")
      window.app.tcl_eval(close_script)

      window.modal_stack.active?.should be_false
      window.app.winfo.exists?(path).should be_true

      window.show_settings
      window.modal_stack.active?.should be_true

      window.destroy
    end
  end

  it "clicking ROM Info's own Close button doesn't permanently lock out future modals" do
    with_tempdir do |dir|
      window = new_window(dir)
      window.load_rom(SPACE_BLAST_ROM)

      window.app.interp.wait_until(5.seconds) do
        window.show_rom_info
        window.modal_stack.active?
      end

      window.app.tcl_invoke(window.rom_info_window.close_button.path, "invoke")
      window.modal_stack.active?.should be_false

      window.show_settings
      window.modal_stack.active?.should be_true

      window.destroy
    end
  end

  it "loading a second ROM stops the first worker cleanly" do
    with_tempdir do |dir|
      window = new_window(dir)
      window.load_rom(FILL_ROM)

      first_worker = window.worker
      raise "expected a worker after load_rom" unless first_worker
      window.app.interp.wait_until(5.seconds) { !first_worker.done? && window.audio.fill_ratio >= 0.0 }

      window.load_rom(SPACE_BLAST_ROM)
      window.app.interp.wait_until(5.seconds) { first_worker.done? }
      first_worker.done?.should be_true

      second_worker = window.worker
      raise "expected a replacement worker after the second load_rom" unless second_worker
      second_worker.should_not be(first_worker)

      second_worker.stop
      window.destroy
    end
  end

  # Writes into the real ~/Library/.../gemba/screenshots (same
  # directory ruby gemba uses, deliberately - see Paths's own doc
  # comment) - cleaned up in `ensure` rather than given a test-only
  # override, since a stray screenshot is harmless additive clutter,
  # unlike a save-state file that could shadow a real one.
  it "#take_screenshot writes a real PNG for the current frame" do
    with_tempdir do |dir|
      window = new_window(dir)
      window.load_rom(SPACE_BLAST_ROM)
      window.app.interp.wait_until(5.seconds) { !window.video.last_frame_argb.nil? }

      before = Dir.exists?(Gemba::Paths.screenshots_dir) ? Dir.children(Gemba::Paths.screenshots_dir) : [] of String
      window.take_screenshot

      # Now round-trips through the worker thread (Core is
      # worker-thread-only) rather than writing synchronously on Tk's
      # own thread, so the file isn't guaranteed to exist - or be done
      # with its default 2x upscale rewrite, see MainWindow#
      # upscale_screenshot - the instant #take_screenshot returns.
      new_files = [] of String
      window.app.interp.wait_until(5.seconds) do
        new_files = Dir.exists?(Gemba::Paths.screenshots_dir) ? Dir.children(Gemba::Paths.screenshots_dir) - before : [] of String
        new_files.size == 1
      end

      path = File.join(Gemba::Paths.screenshots_dir, new_files.first)
      new_files.first.should start_with "space_blast_"
      new_files.first.should end_with ".png"

      # The worker's raw native-resolution write lands on disk (and so
      # in the Dir.children check above) BEFORE the upscale rewrite that
      # only happens once the main thread processes the worker's
      # message - so this polls for the FINAL (scaled) size rather than
      # trusting the file's mere existence. A mid-rewrite partial read
      # is expected to fail; that's "not ready yet", not a real error.
      width = height = 0
      window.app.interp.wait_until(5.seconds) do
        photo = Tryst::Photo.new(window.app, file: path)
        size = photo.get_size
        width, height = size[:width], size[:height]
        photo.delete
        width == window.video.native_width * 2 && height == window.video.native_height * 2
      rescue Tryst::TclError
        false
      end
      width.should eq window.video.native_width * 2
      height.should eq window.video.native_height * 2

      File.delete(path)
      window.worker.try(&.stop)
      window.destroy
    end
  end

  it "ROM-dependent menu items start disabled and enable once a ROM loads" do
    with_tempdir do |dir|
      window = new_window(dir)

      window.rom_info_item.try(&.options["state"]).should eq "disabled"
      window.quick_save_item.try(&.options["state"]).should eq "disabled"
      window.quick_load_item.try(&.options["state"]).should eq "disabled"
      window.save_states_item.try(&.options["state"]).should eq "disabled"

      window.load_rom(SPACE_BLAST_ROM)

      window.rom_info_item.try(&.options["state"]).should eq "normal"
      window.quick_save_item.try(&.options["state"]).should eq "normal"
      window.quick_load_item.try(&.options["state"]).should eq "normal"
      window.save_states_item.try(&.options["state"]).should eq "normal"

      window.worker.try(&.stop)
      window.destroy
    end
  end

  it "double-clicking an empty slot in the real, wired-up picker saves a state and writes its thumbnail" do
    with_tempdir do |dir|
      window = new_window(dir)
      window.load_rom(SPACE_BLAST_ROM)

      window.app.interp.wait_until(5.seconds) do
        window.show_save_states
        window.modal_stack.active?
      end

      thumb_path = "#{window.save_state_picker.handle.path}.grid.slot1.thumb"
      invoke_binding(window.app, thumb_path, "<Double-Button-1>")

      frame = window.emulator_frame
      raise "expected an emulator frame after load_rom" unless frame
      state_dir = frame.state_dir
      raise "expected a state_dir once show_save_states has succeeded" unless state_dir
      window.app.interp.wait_until(5.seconds) { File.exists?(Gemba::SaveStateManager.state_path(state_dir, 1)) }
      window.app.interp.wait_until(5.seconds) { File.exists?(Gemba::SaveStateManager.screenshot_path(state_dir, 1)) }

      window.worker.try(&.stop)
      window.destroy
    end
  end

  it "the pause hotkey still works after a modal (e.g. Settings) closes" do
    with_tempdir do |dir|
      window = new_window(dir)
      window.load_rom(SPACE_BLAST_ROM)
      window.app.interp.wait_until(5.seconds) { !window.video.last_frame_argb.nil? }

      window.show_settings
      window.modal_stack.active?.should be_true
      window.modal_stack.pop
      window.modal_stack.active?.should be_false

      frame = window.emulator_frame
      raise "expected an emulator frame after load_rom" unless frame
      paused_before = frame.paused?

      window.app.tcl_eval("event generate . <p>")
      window.app.update

      frame.paused?.should_not eq paused_before

      window.worker.try(&.stop)
      window.destroy
    end
  end

  it "a hotkey customized to a Shift+letter combo (e.g. pause rebound to Shift+P) fires on a real keypress" do
    with_tempdir do |dir|
      config_path = File.join(dir, "settings.json")
      File.write(config_path, %({"global": {}, "gamepads": {}, "hotkeys": {"pause": ["Shift", "p"]}, "recent_roms": []}))

      window = Gemba::MainWindow.new(
        rom_library_path: File.join(dir, "rom_library.json"),
        config_path: config_path,
        gamepad_polling: false,
      )
      window.load_rom(SPACE_BLAST_ROM)
      window.app.interp.wait_until(5.seconds) { !window.video.last_frame_argb.nil? }

      frame = window.emulator_frame
      raise "expected an emulator frame after load_rom" unless frame
      paused_before = frame.paused?

      window.app.interp.simulate_event(".", "<P>")
      window.app.interp.wait_until(2.seconds) { frame.paused? != paused_before }

      frame.paused?.should_not eq paused_before

      window.worker.try(&.stop)
      window.destroy
    end
  end
end
