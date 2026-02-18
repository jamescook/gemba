# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestMGBASettingsHotkeys < Minitest::Test
  include TeekTestHelper

  def test_hotkeys_tab_exists
    assert_tk_app("hotkeys tab exists in notebook") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      tabs = app.command(Gemba::SettingsWindow::NB, 'tabs')
      assert_includes tabs, Gemba::SettingsWindow::HK_TAB
    end
  end

  def test_hotkey_buttons_show_default_keysyms
    assert_tk_app("hotkey buttons show default keysyms") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'q', text
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:pause], 'cget', '-text')
      assert_equal 'p', text
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quick_save], 'cget', '-text')
      assert_equal 'F5', text
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:screenshot], 'cget', '-text')
      assert_equal 'F9', text
    end
  end

  def test_clicking_hotkey_button_enters_listen_mode
    assert_tk_app("clicking hotkey button enters listen mode") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update

      assert_equal :quit, sw.hk_listening_for
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal "Press\u2026", text
    end
  end

  def test_capture_updates_label_and_fires_callback
    assert_tk_app("capturing hotkey updates label and fires callback") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received_action = nil
      received_key = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |a, k| received_action = a; received_key = k }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Click to start listening for quit hotkey
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update

      # Simulate key capture
      sw.capture_hk_mapping('Escape')
      app.update

      assert_nil sw.hk_listening_for
      assert_equal :quit, received_action
      assert_equal 'Escape', received_key
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'Escape', text
    end
  end

  def test_capture_enables_undo_button
    assert_tk_app("capturing hotkey enables undo button") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Initially disabled
      state = app.command(Gemba::SettingsWindow::HK_UNDO_BTN, 'cget', '-state')
      assert_equal 'disabled', state

      # Rebind
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:pause], 'invoke')
      app.update
      sw.capture_hk_mapping('F12')
      app.update

      state = app.command(Gemba::SettingsWindow::HK_UNDO_BTN, 'cget', '-state')
      assert_equal 'normal', state
    end
  end

  def test_undo_fires_callback_and_disables
    assert_tk_app("undo fires on_undo_hotkeys and disables button") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      undo_called = false
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:undo_hotkeys) { undo_called = true }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Rebind to enable undo
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update
      sw.capture_hk_mapping('Escape')
      app.update

      # Click undo
      app.command(Gemba::SettingsWindow::HK_UNDO_BTN, 'invoke')
      app.update

      assert undo_called
      state = app.command(Gemba::SettingsWindow::HK_UNDO_BTN, 'cget', '-state')
      assert_equal 'disabled', state
    end
  end

  def test_reset_restores_defaults
    assert_tk_app("reset restores default hotkey labels") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      reset_called = false
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_reset) { reset_called = true }
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_confirm_reset_hotkeys: -> { true },
      })
      sw.show
      app.update

      # Rebind quit
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update
      sw.capture_hk_mapping('Escape')
      app.update

      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'Escape', text

      # Click Reset to Defaults
      app.command(Gemba::SettingsWindow::HK_RESET_BTN, 'invoke')
      app.update

      assert reset_called
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'q', text
      state = app.command(Gemba::SettingsWindow::HK_UNDO_BTN, 'cget', '-state')
      assert_equal 'disabled', state
    end
  end

  def test_refresh_hotkeys_updates_labels
    assert_tk_app("refresh_hotkeys updates button labels") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      new_labels = Gemba::HotkeyMap::DEFAULTS.merge(quit: 'Escape', pause: 'F12')
      sw.refresh_hotkeys(new_labels)
      app.update

      assert_equal 'Escape', app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'F12', app.command(Gemba::SettingsWindow::HK_ACTIONS[:pause], 'cget', '-text')
      # Unchanged bindings stay the same
      assert_equal 'Tab', app.command(Gemba::SettingsWindow::HK_ACTIONS[:fast_forward], 'cget', '-text')
    end
  end

  def test_cancel_listen_restores_label
    assert_tk_app("canceling listen restores original label") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Enter listen for quit
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update
      assert_equal :quit, sw.hk_listening_for

      # Start listening for a different one — cancels the first
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:pause], 'invoke')
      app.update

      assert_equal :pause, sw.hk_listening_for
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'q', text, "Original quit label should be restored"
    end
  end

  def test_capture_without_listen_is_noop
    assert_tk_app("capture without listen mode is a no-op") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received = false
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |*| received = true }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Capture without entering listen mode
      sw.capture_hk_mapping('F12')
      app.update

      refute received
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'q', text, "Label should be unchanged"
    end
  end

  # -- Conflict validation ---------------------------------------------------

  def test_hotkey_rejected_when_conflicting_with_gamepad_key
    assert_tk_app("hotkey rejected when key conflicts with gamepad mapping") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received = false
      conflict_msg = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |*| received = true }
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_validate_hotkey: ->(keysym) {
          # Simulate: 'z' is GBA button A
          keysym == 'z' ? '"z" is mapped to GBA button A' : nil
        },
        on_key_conflict: proc { |msg| conflict_msg = msg },
      })
      sw.show
      app.update

      # Try to bind quit to 'z' (conflicts with GBA A)
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update
      sw.capture_hk_mapping('z')
      app.update

      refute received, "on_hotkey_change should not fire for rejected key"
      assert_equal '"z" is mapped to GBA button A', conflict_msg
      # Label should revert to original, not show 'z'
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'q', text
      assert_nil sw.hk_listening_for
    end
  end

  def test_hotkey_accepted_when_no_conflict
    assert_tk_app("hotkey accepted when no conflict") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received_action = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |a, _| received_action = a }
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_validate_hotkey: ->(_) { nil },
      })
      sw.show
      app.update

      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update
      sw.capture_hk_mapping('F12')
      app.update

      assert_equal :quit, received_action
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'F12', text
    end
  end

  # -- Modifier combo capture -----------------------------------------------

  def test_capture_modifier_then_key_produces_combo
    assert_tk_app("modifier + key produces combo hotkey") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received_action = nil
      received_hk = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |a, hk| received_action = a; received_hk = hk }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Enter listen mode for quit
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update

      # Simulate pressing Control_L (modifier), then 'k' (non-modifier)
      sw.capture_hk_mapping('Control_L')
      sw.capture_hk_mapping('k')
      app.update

      assert_equal :quit, received_action
      assert_equal ['Control', 'k'], received_hk
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'Ctrl+K', text
      assert_nil sw.hk_listening_for
    end
  end

  def test_capture_multi_modifier_combo
    assert_tk_app("multi-modifier combo (Ctrl+Shift+S)") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received_hk = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |_, hk| received_hk = hk }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      app.command(Gemba::SettingsWindow::HK_ACTIONS[:screenshot], 'invoke')
      app.update

      sw.capture_hk_mapping('Control_L')
      sw.capture_hk_mapping('Shift_L')
      sw.capture_hk_mapping('s')
      app.update

      assert_equal ['Control', 'Shift', 's'], received_hk
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:screenshot], 'cget', '-text')
      assert_equal 'Ctrl+Shift+S', text
    end
  end

  def test_combo_hotkey_skips_gamepad_conflict_validation
    assert_tk_app("combo hotkey skips gamepad conflict validation") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received_hk = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |_, hk| received_hk = hk }
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        # 'z' conflicts as a plain key, but Ctrl+z should be fine
        on_validate_hotkey: ->(key) {
          key == 'z' ? '"z" is mapped to GBA button A' : nil
        },
      })
      sw.show
      app.update

      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update

      sw.capture_hk_mapping('Control_L')
      sw.capture_hk_mapping('z')
      app.update

      assert_equal ['Control', 'z'], received_hk, "Ctrl+Z combo should bypass plain-key conflict"
    end
  end

  def test_refresh_hotkeys_shows_combo_display_name
    assert_tk_app("refresh_hotkeys shows combo display name") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      new_labels = Gemba::HotkeyMap::DEFAULTS.merge(quit: ['Control', 'q'])
      sw.refresh_hotkeys(new_labels)
      app.update

      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'Ctrl+Q', text
    end
  end

  def test_bind_script_modifier_combo_roundtrip
    assert_tk_app("Tcl bind script round-trip with modifier+key combo") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      received_hk = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:hotkey_changed) { |_, hk| received_hk = hk }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Enter listen mode
      top = Gemba::SettingsWindow::TOP
      app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'invoke')
      app.update

      # Verify the <Key> bind script was installed on the toplevel
      bind_script = app.tcl_eval("bind #{top} <Key>")
      refute_empty bind_script, "Key binding should be set during listen mode"
      assert_match(/ruby_callback/, bind_script)

      # Simulate what Tk does on key events: evaluate the bind script
      # with %K substituted to the keysym value
      app.tcl_eval(bind_script.gsub('%K', 'Control_L'))
      app.update
      app.tcl_eval(bind_script.gsub('%K', 'k'))
      app.update

      assert_equal ['Control', 'k'], received_hk
      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:quit], 'cget', '-text')
      assert_equal 'Ctrl+K', text
    end
  end

  def test_record_hotkey_button_shows_default
    assert_tk_app("record hotkey button shows F10") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:record], 'cget', '-text')
      assert_equal 'F10', text
    end
  end

  def test_open_rom_hotkey_button_shows_default
    assert_tk_app("open rom hotkey button shows Ctrl+O") do
      require "gemba/settings_window"
      require "gemba/hotkey_map"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      text = app.command(Gemba::SettingsWindow::HK_ACTIONS[:open_rom], 'cget', '-text')
      assert_equal 'Ctrl+O', text
    end
  end
end
