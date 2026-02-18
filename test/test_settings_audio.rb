# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestSettingsAudioTab < Minitest::Test
  include TeekTestHelper

  # -- Volume slider ------------------------------------------------------

  def test_volume_defaults_to_100
    assert_tk_app("volume defaults to 100") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      assert_equal '100', app.get_variable(Gemba::Settings::AudioTab::VAR_VOLUME)
    end
  end

  def test_dragging_volume_to_50_fires_callback
    assert_tk_app("dragging volume to 50 fires on_volume_change") do
      require "gemba/settings_window"
      received = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:volume_changed) { |v| received = v }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Simulate user dragging volume slider to 50
      app.command(Gemba::Settings::AudioTab::VOLUME_SCALE, 'set', 50)
      app.update

      assert_in_delta 0.5, received, 0.01
    end
  end

  def test_volume_at_zero
    assert_tk_app("volume at zero") do
      require "gemba/settings_window"
      received = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:volume_changed) { |v| received = v }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      app.command(Gemba::Settings::AudioTab::VOLUME_SCALE, 'set', 0)
      app.update

      assert_in_delta 0.0, received, 0.01
    end
  end

  # -- Mute checkbox ------------------------------------------------------

  def test_mute_defaults_to_off
    assert_tk_app("mute defaults to off") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      assert_equal '0', app.get_variable(Gemba::Settings::AudioTab::VAR_MUTE)
    end
  end

  def test_clicking_mute_fires_callback
    assert_tk_app("clicking mute fires on_mute_change") do
      require "gemba/settings_window"
      received = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:mute_changed) { |m| received = m }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      # Simulate user clicking the mute checkbox
      app.command(Gemba::Settings::AudioTab::MUTE_CHECK, 'invoke')
      app.update

      assert_equal true, received
    end
  end

  def test_clicking_mute_twice_unmutes
    assert_tk_app("clicking mute twice unmutes") do
      require "gemba/settings_window"
      received = nil
      Gemba.bus = Gemba::EventBus.new
      Gemba.bus.on(:mute_changed) { |m| received = m }
      sw = Gemba::SettingsWindow.new(app)
      sw.show
      app.update

      app.command(Gemba::Settings::AudioTab::MUTE_CHECK, 'invoke')
      app.update
      assert_equal true, received

      app.command(Gemba::Settings::AudioTab::MUTE_CHECK, 'invoke')
      app.update
      assert_equal false, received
    end
  end
end
