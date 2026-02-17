# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestSettingsSaveStatesTab < Minitest::Test
  include TeekTestHelper

  def test_save_states_tab_exists
    assert_tk_app("save states tab exists in notebook") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      tabs = app.command(Gemba::Settings::Paths::NB, 'tabs')
      assert_includes tabs, Gemba::Settings::SaveStatesTab::FRAME
    end
  end

  def test_quick_slot_defaults_to_1
    assert_tk_app("quick slot defaults to 1") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1', app.get_variable(Gemba::Settings::SaveStatesTab::VAR_QUICK_SLOT)
    end
  end

  def test_selecting_slot_fires_callback
    assert_tk_app("selecting slot fires on_quick_slot_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_quick_slot_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.set_variable(Gemba::Settings::SaveStatesTab::VAR_QUICK_SLOT, '5')
      app.command(:event, 'generate', Gemba::Settings::SaveStatesTab::SLOT_COMBO, '<<ComboboxSelected>>')
      app.update

      assert_equal 5, received
    end
  end

  def test_backup_defaults_to_on
    assert_tk_app("backup checkbox defaults to on") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1', app.get_variable(Gemba::Settings::SaveStatesTab::VAR_BACKUP)
    end
  end

  def test_clicking_backup_fires_callback
    assert_tk_app("clicking backup fires on_backup_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_backup_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::SaveStatesTab::BACKUP_CHECK, 'invoke')
      app.update

      assert_equal false, received
    end
  end

  def test_clicking_backup_twice_re_enables
    assert_tk_app("clicking backup twice re-enables") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_backup_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::SaveStatesTab::BACKUP_CHECK, 'invoke')
      app.update
      assert_equal false, received

      app.command(Gemba::Settings::SaveStatesTab::BACKUP_CHECK, 'invoke')
      app.update
      assert_equal true, received
    end
  end
end
