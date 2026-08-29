require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("main_window_gamepad_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Separate from main_window_spec.cr on purpose: every example here needs
# gamepad_polling: true, and exercises Tryst::SDL::Gamepad's real (if
# virtual) hot-plug machinery - a heavier, slower path than anything
# else in that file, which all opt OUT of it (see its own doc comment on
# why). Every example attaches/detaches its own virtual gamepad in an
# ensure block so a later spec (in this file or another) never sees one
# left dangling.
private def new_window(dir : String) : Gemba::MainWindow
  Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: true,
  )
end

# GamepadTab's own device-select combobox is bound to a fixed, global
# Tcl variable name (not one this class exposes) - see its own
# @gp_var - and, same as every other classic Tk widget's instance
# binding in this codebase's specs, a synthetic `event generate`
# reaches it fine since <<ComboboxSelected>> is the virtual event
# GamepadTab itself binds, not a class binding.
private def select_gamepad_device(window : Gemba::MainWindow, name : String) : Nil
  window.app.set_variable("::gemba_gamepad_device", name)
  window.app.interp.simulate_event(window.settings_window.gamepad_tab.gp_combo, "<<ComboboxSelected>>")
end

describe Gemba::MainWindow do
  describe "gamepad hot-plug" do
    it "picks up a gamepad already connected at construction, with no wait needed" do
      with_tempdir do |dir|
        id = Tryst::SDL::Gamepad.attach_virtual
        begin
          window = new_window(dir)
          begin
            window.gamepad_map.device.try(&.instance_id).should eq id
            window.settings_window.gamepad_tab.path # sanity: tab built fine
          ensure
            window.app.destroy
          end
        ensure
          Tryst::SDL::Gamepad.detach_virtual
        end
      end
    end

    it "hot-plugs a gamepad connected after startup" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          window.gamepad_map.device.should be_nil

          id = Tryst::SDL::Gamepad.attach_virtual
          begin
            window.app.interp.wait_until(5.seconds) { !window.gamepad_map.device.nil? }
            window.gamepad_map.device.try(&.instance_id).should eq id
          ensure
            Tryst::SDL::Gamepad.detach_virtual
          end
        ensure
          window.app.destroy
        end
      end
    end

    it "clears the device on removal and can pick up a replacement afterward" do
      with_tempdir do |dir|
        window = new_window(dir)
        begin
          first_id = Tryst::SDL::Gamepad.attach_virtual
          window.app.interp.wait_until(5.seconds) { !window.gamepad_map.device.nil? }

          Tryst::SDL::Gamepad.detach_virtual
          window.app.interp.wait_until(5.seconds) { window.gamepad_map.device.nil? }
          window.gamepad_map.device.should be_nil

          second_id = Tryst::SDL::Gamepad.attach_virtual
          begin
            window.app.interp.wait_until(5.seconds) { !window.gamepad_map.device.nil? }
            window.gamepad_map.device.try(&.instance_id).should eq second_id
            second_id.should_not eq first_id
          ensure
            Tryst::SDL::Gamepad.detach_virtual
          end
        ensure
          window.app.destroy
        end
      end
    end

    # Doesn't drive an actual SDL button press through
    # #gamepad_probe_tick's own polling loop: a live Tryst::SDL::Viewport
    # (which MainWindow always has, for real video output) makes a
    # virtual gamepad's simulated button state permanently unobservable
    # in this environment - confirmed directly with an isolated repro
    # (SDL3, this same Docker image): identical code sees the press
    # instantly with no Viewport open, never with one, regardless of
    # update_state/poll_events or how long it waits. Not a bug in this
    # class - tracked as its own gap (discovered-from this bead) since a
    # real controller doesn't have this problem; this spec instead
    # verifies the wiring #gamepad_probe_tick's scan itself would
    # exercise (Events#gamepad_mapping_changed -> GamepadMap#set) by
    # calling #capture_mapping directly, the same call the scan makes
    # once it finds a held button.
    it "wires a captured gamepad button name through Events into GamepadMap, once in gamepad mode" do
      with_tempdir do |dir|
        Tryst::SDL::Gamepad.attach_virtual
        begin
          window = new_window(dir)
          begin
            gamepad = window.gamepad_map.device
            gamepad.should_not be_nil
            next unless gamepad # unreachable - satisfies the compiler below

            window.show_settings
            window.settings_window.select_gamepad_tab
            select_gamepad_device(window, gamepad.name)
            window.settings_window.gamepad_tab.keyboard_mode?.should be_false

            seen = [] of {Gemba::Button, String}
            window.events.gamepad_mapping_changed.connect { |btn, name| seen << {btn, name} }

            window.settings_window.gamepad_tab.start_listening(Gemba::Button::A)
            window.settings_window.gamepad_tab.capture_mapping("b")

            seen.should eq [{Gemba::Button::A, "b"}]
            window.gamepad_map.labels[Gemba::Button::A].should eq :b
          ensure
            window.app.destroy
          end
        ensure
          Tryst::SDL::Gamepad.detach_virtual
        end
      end
    end
  end
end
