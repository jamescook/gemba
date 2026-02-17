# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestSettingsRecordingTab < Minitest::Test
  include TeekTestHelper

  def test_recording_tab_exists
    assert_tk_app("recording tab exists in notebook") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      tabs = app.command(Gemba::Settings::Paths::NB, 'tabs')
      assert_includes tabs, Gemba::Settings::RecordingTab::FRAME
    end
  end

  def test_compression_combobox_defaults_to_1
    assert_tk_app("compression combobox defaults to 1") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1', app.get_variable(Gemba::Settings::RecordingTab::VAR_COMPRESSION)
    end
  end

  def test_selecting_compression_fires_callback
    assert_tk_app("selecting compression fires on_compression_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_compression_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.set_variable(Gemba::Settings::RecordingTab::VAR_COMPRESSION, '6')
      app.command(:event, 'generate', Gemba::Settings::RecordingTab::COMPRESSION_COMBO, '<<ComboboxSelected>>')
      app.update

      assert_equal 6, received
    end
  end
end
