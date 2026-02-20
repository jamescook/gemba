# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestSettingsSystem < Minitest::Test
  include TeekTestHelper

  FAKE_BIOS = File.expand_path("fixtures/fake_bios.bin", __dir__)

  # -- tab presence -----------------------------------------------------------

  def test_system_tab_exists_in_notebook
    assert_tk_app("system tab exists in notebook") do
      require "gemba/headless"
      Gemba.bus = Gemba::EventBus.new
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      tabs = app.command(Gemba::SettingsWindow::NB, 'tabs').split
      assert_includes tabs, Gemba::SettingsWindow::SYSTEM_TAB
    end
  end

  # -- initial state ----------------------------------------------------------

  def test_bios_path_empty_initially
    assert_tk_app("bios path var is empty initially") do
      require "gemba/headless"
      Gemba.bus = Gemba::EventBus.new
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      val = app.get_variable(Gemba::SettingsWindow::VAR_BIOS_PATH)
      assert_equal '', val
    end
  end

  def test_skip_bios_unchecked_initially
    assert_tk_app("skip bios checkbox is unchecked initially") do
      require "gemba/headless"
      Gemba.bus = Gemba::EventBus.new
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      val = app.get_variable(Gemba::SettingsWindow::VAR_SKIP_BIOS)
      assert_equal '0', val
    end
  end

  # -- skip_bios checkbox marks dirty ----------------------------------------

  def test_skip_bios_toggle_marks_save_dirty
    assert_tk_app("toggling skip bios enables the save button") do
      require "gemba/headless"
      Gemba.bus = Gemba::EventBus.new
      sw = Gemba::SettingsWindow.new(app)
      sw.show

      # Navigate to system tab
      app.command(Gemba::SettingsWindow::NB, 'select', Gemba::SettingsWindow::SYSTEM_TAB)
      app.update

      app.command(Gemba::Settings::SystemTab::SKIP_BIOS_CHECK, 'invoke')
      app.update

      state = app.command(Gemba::SettingsWindow::SAVE_BTN, :cget, '-state').to_s
      assert_equal 'normal', state
    end
  end

  # -- clear button -----------------------------------------------------------

  def test_clear_button_empties_bios_path
    assert_tk_app("clear button empties the bios path variable") do
      require "gemba/headless"
      Gemba.bus = Gemba::EventBus.new
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Seed a value
      app.set_variable(Gemba::SettingsWindow::VAR_BIOS_PATH, 'gba_bios.bin')
      app.command(Gemba::Settings::SystemTab::BIOS_CLEAR, 'invoke')
      app.update

      assert_equal '', app.get_variable(Gemba::SettingsWindow::VAR_BIOS_PATH)
    end
  end

  def test_clear_button_marks_save_dirty
    assert_tk_app("clear button enables the save button") do
      require "gemba/headless"
      Gemba.bus = Gemba::EventBus.new
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      app.command(Gemba::Settings::SystemTab::BIOS_CLEAR, 'invoke')
      app.update

      state = app.command(Gemba::SettingsWindow::SAVE_BTN, :cget, '-state').to_s
      assert_equal 'normal', state
    end
  end

  def test_clear_resets_status_label
    assert_tk_app("clear button resets status label to not-set text") do
      require "gemba/headless"
      Gemba::Locale.load('en')
      Gemba.bus = Gemba::EventBus.new
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      app.command(Gemba::Settings::SystemTab::BIOS_CLEAR, 'invoke')
      app.update

      text = app.command(Gemba::Settings::SystemTab::BIOS_STATUS, :cget, '-text').to_s
      assert_includes text, 'Not set'
    end
  end

  # -- system tab is per-game eligible ----------------------------------------

  def test_system_tab_in_per_game_tabs
    require "gemba/headless"
    assert Gemba::SettingsWindow::PER_GAME_TABS.include?(Gemba::SettingsWindow::SYSTEM_TAB)
  end
end
