# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestHelpWindow < Minitest::Test
  include TeekTestHelper

  # HelpWindow is wm transient to '.'. The TestWorker withdraws '.' after each
  # test, so a transient child can't be shown unless we deiconify '.' first.
  # app.show deiconifies the root window for tests that check visibility.

  def test_visible_after_show
    assert_tk_app("help window is visible after show") do
      require "gemba/headless"

      hotkeys = Struct.new(:m) { def key_for(a) = Gemba::HotkeyMap::DEFAULTS[a] }.new(nil)
      win = Gemba::HelpWindow.new(app: app, hotkeys: hotkeys)
      app.show
      win.show
      app.update  # flush pending Tk map events before checking visibility

      assert win.visible?, "help window should be visible after show"

      win.hide
      app.command(:destroy, Gemba::HelpWindow::TOP) rescue nil
    end
  end

  def test_hidden_after_hide
    assert_tk_app("help window is hidden after hide") do
      require "gemba/headless"

      hotkeys = Struct.new(:m) { def key_for(a) = Gemba::HotkeyMap::DEFAULTS[a] }.new(nil)
      win = Gemba::HelpWindow.new(app: app, hotkeys: hotkeys)
      app.show
      win.show
      win.hide

      refute win.visible?, "help window should not be visible after hide"

      app.command(:destroy, Gemba::HelpWindow::TOP) rescue nil
    end
  end

  def test_rows_show_action_labels
    assert_tk_app("help window rows show translated action labels") do
      require "gemba/headless"

      hotkeys = Struct.new(:m) { def key_for(a) = Gemba::HotkeyMap::DEFAULTS[a] }.new(nil)
      win = Gemba::HelpWindow.new(app: app, hotkeys: hotkeys)
      win.show

      text = app.command("#{Gemba::HelpWindow::TOP}.f.row_pause.act", :cget, '-text')
      assert_equal 'Pause', text, "pause row should show 'Pause' label"

      win.hide
      app.command(:destroy, Gemba::HelpWindow::TOP) rescue nil
    end
  end

  def test_rows_show_key_display
    assert_tk_app("help window rows show formatted key names") do
      require "gemba/headless"

      hotkeys = Struct.new(:m) { def key_for(a) = Gemba::HotkeyMap::DEFAULTS[a] }.new(nil)
      win = Gemba::HelpWindow.new(app: app, hotkeys: hotkeys)
      win.show

      # pause default is 'p'
      text = app.command("#{Gemba::HelpWindow::TOP}.f.row_pause.key", :cget, '-text')
      assert_equal 'p', text, "pause row key should show 'p'"

      # quick_save default is 'F5'
      text = app.command("#{Gemba::HelpWindow::TOP}.f.row_quick_save.key", :cget, '-text')
      assert_equal 'F5', text, "quick_save row key should show 'F5'"

      win.hide
      app.command(:destroy, Gemba::HelpWindow::TOP) rescue nil
    end
  end
end
