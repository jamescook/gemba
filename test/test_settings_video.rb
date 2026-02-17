# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestSettingsVideoTab < Minitest::Test
  include TeekTestHelper

  def test_video_tab_exists
    assert_tk_app("video tab exists in notebook") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      tabs = app.command(Gemba::Settings::Paths::NB, 'tabs')
      assert_includes tabs, Gemba::Settings::VideoTab::FRAME
    end
  end

  # -- Scale combobox --------------------------------------------------------

  def test_scale_defaults_to_3x
    assert_tk_app("scale combobox defaults to 3x") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '3x', app.get_variable(Gemba::Settings::VideoTab::VAR_SCALE)
    end
  end

  def test_selecting_2x_scale_fires_callback
    assert_tk_app("selecting 2x scale fires on_scale_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_scale_change: proc { |s| received = s }
      })
      sw.show
      app.update

      app.set_variable(Gemba::Settings::VideoTab::VAR_SCALE, '2x')
      app.command(:event, 'generate', Gemba::Settings::VideoTab::SCALE_COMBO, '<<ComboboxSelected>>')
      app.update

      assert_equal 2, received
    end
  end

  def test_selecting_4x_scale_fires_callback
    assert_tk_app("selecting 4x scale fires on_scale_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_scale_change: proc { |s| received = s }
      })
      sw.show
      app.update

      app.set_variable(Gemba::Settings::VideoTab::VAR_SCALE, '4x')
      app.command(:event, 'generate', Gemba::Settings::VideoTab::SCALE_COMBO, '<<ComboboxSelected>>')
      app.update

      assert_equal 4, received
    end
  end

  # -- Turbo speed combobox --------------------------------------------------

  def test_turbo_defaults_to_2x
    assert_tk_app("turbo speed defaults to 2x") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '2x', app.get_variable(Gemba::Settings::VideoTab::VAR_TURBO)
    end
  end

  def test_selecting_4x_turbo_fires_callback
    assert_tk_app("selecting 4x turbo fires on_turbo_speed_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_turbo_speed_change: proc { |s| received = s }
      })
      sw.show
      app.update

      app.set_variable(Gemba::Settings::VideoTab::VAR_TURBO, '4x')
      app.command(:event, 'generate', Gemba::Settings::VideoTab::TURBO_COMBO, '<<ComboboxSelected>>')
      app.update

      assert_equal 4, received
    end
  end

  # -- Aspect ratio checkbox -------------------------------------------------

  def test_aspect_ratio_defaults_to_on
    assert_tk_app("aspect ratio checkbox defaults to on") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1', app.get_variable(Gemba::Settings::VideoTab::VAR_ASPECT_RATIO)
    end
  end

  def test_unchecking_aspect_ratio_fires_callback
    assert_tk_app("unchecking aspect ratio fires on_aspect_ratio_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_aspect_ratio_change: proc { |keep| received = keep }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::ASPECT_CHECK, 'invoke')
      app.update

      assert_equal false, received
    end
  end

  def test_checking_aspect_ratio_fires_callback
    assert_tk_app("re-checking aspect ratio fires callback with true") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_aspect_ratio_change: proc { |keep| received = keep }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::ASPECT_CHECK, 'invoke')
      app.update
      app.command(Gemba::Settings::VideoTab::ASPECT_CHECK, 'invoke')
      app.update

      assert_equal true, received
    end
  end

  # -- Show FPS checkbox -----------------------------------------------------

  def test_show_fps_defaults_to_on
    assert_tk_app("show fps checkbox defaults to on") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1', app.get_variable(Gemba::Settings::VideoTab::VAR_SHOW_FPS)
    end
  end

  def test_unchecking_show_fps_fires_callback
    assert_tk_app("unchecking show fps fires on_show_fps_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_show_fps_change: proc { |show| received = show }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::SHOW_FPS_CHECK, 'invoke')
      app.update

      assert_equal false, received
    end
  end

  # -- Pause on focus loss checkbox ------------------------------------------

  def test_pause_focus_defaults_to_on
    assert_tk_app("pause on focus loss defaults to on") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1', app.get_variable(Gemba::Settings::VideoTab::VAR_PAUSE_FOCUS)
    end
  end

  def test_unchecking_pause_focus_fires_callback
    assert_tk_app("unchecking pause on focus loss fires callback") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_pause_on_focus_loss_change: proc { |v| received = v }
      })
      sw.show
      app.update

      # The pause focus checkbox path
      pause_check = "#{Gemba::Settings::VideoTab::FRAME}.pause_focus_row.check"
      app.command(pause_check, 'invoke')
      app.update

      assert_equal false, received
    end
  end

  # -- Toast duration combobox -----------------------------------------------

  def test_toast_duration_defaults_to_1_5s
    assert_tk_app("toast duration defaults to 1.5s") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1.5s', app.get_variable(Gemba::Settings::VideoTab::VAR_TOAST_DURATION)
    end
  end

  def test_selecting_3s_toast_fires_callback
    assert_tk_app("selecting 3s toast fires on_toast_duration_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_toast_duration_change: proc { |s| received = s }
      })
      sw.show
      app.update

      app.set_variable(Gemba::Settings::VideoTab::VAR_TOAST_DURATION, '3s')
      app.command(:event, 'generate', Gemba::Settings::VideoTab::TOAST_COMBO, '<<ComboboxSelected>>')
      app.update

      assert_in_delta 3.0, received
    end
  end

  # -- Pixel filter combobox -------------------------------------------------

  def test_pixel_filter_defaults_to_nearest
    assert_tk_app("pixel filter defaults to Nearest Neighbor") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal 'Nearest Neighbor', app.get_variable(Gemba::Settings::VideoTab::VAR_FILTER)
    end
  end

  def test_selecting_bilinear_fires_callback
    assert_tk_app("selecting Bilinear fires on_filter_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_filter_change: proc { |f| received = f }
      })
      sw.show
      app.update

      app.set_variable(Gemba::Settings::VideoTab::VAR_FILTER, 'Bilinear')
      app.command(:event, 'generate', Gemba::Settings::VideoTab::FILTER_COMBO, '<<ComboboxSelected>>')
      app.update

      assert_equal 'linear', received
    end
  end

  # -- Integer scaling checkbox ----------------------------------------------

  def test_integer_scale_defaults_to_off
    assert_tk_app("integer scale checkbox defaults to off") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '0', app.get_variable(Gemba::Settings::VideoTab::VAR_INTEGER_SCALE)
    end
  end

  def test_clicking_integer_scale_fires_callback
    assert_tk_app("clicking integer scale fires on_integer_scale_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_integer_scale_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::INTEGER_SCALE_CHECK, 'invoke')
      app.update

      assert_equal true, received
    end
  end

  # -- Color correction checkbox ---------------------------------------------

  def test_color_correction_defaults_to_off
    assert_tk_app("color correction checkbox defaults to off") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '0', app.get_variable(Gemba::Settings::VideoTab::VAR_COLOR_CORRECTION)
    end
  end

  def test_clicking_color_correction_fires_callback
    assert_tk_app("clicking color correction fires on_color_correction_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_color_correction_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::COLOR_CORRECTION_CHECK, 'invoke')
      app.update

      assert_equal true, received
    end
  end

  def test_unchecking_color_correction_fires_false
    assert_tk_app("unchecking color correction fires callback with false") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_color_correction_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::COLOR_CORRECTION_CHECK, 'invoke')
      app.update
      app.command(Gemba::Settings::VideoTab::COLOR_CORRECTION_CHECK, 'invoke')
      app.update

      assert_equal false, received
    end
  end

  # -- Frame blending checkbox -----------------------------------------------

  def test_frame_blending_defaults_to_off
    assert_tk_app("frame blending checkbox defaults to off") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '0', app.get_variable(Gemba::Settings::VideoTab::VAR_FRAME_BLENDING)
    end
  end

  def test_clicking_frame_blending_fires_callback
    assert_tk_app("clicking frame blending fires on_frame_blending_change") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_frame_blending_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::FRAME_BLENDING_CHECK, 'invoke')
      app.update

      assert_equal true, received
    end
  end

  def test_unchecking_frame_blending_fires_false
    assert_tk_app("unchecking frame blending fires callback with false") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_frame_blending_change: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::FRAME_BLENDING_CHECK, 'invoke')
      app.update
      app.command(Gemba::Settings::VideoTab::FRAME_BLENDING_CHECK, 'invoke')
      app.update

      assert_equal false, received
    end
  end

  # -- Rewind checkbox -------------------------------------------------------

  def test_rewind_defaults_to_on
    assert_tk_app("rewind checkbox defaults to on") do
      require "gemba/settings_window"
      sw = Gemba::SettingsWindow.new(app, callbacks: {})
      sw.show
      app.update

      assert_equal '1', app.get_variable(Gemba::Settings::VideoTab::VAR_REWIND_ENABLED)
    end
  end

  def test_clicking_rewind_fires_callback
    assert_tk_app("clicking rewind fires on_rewind_toggle") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_rewind_toggle: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::REWIND_CHECK, 'invoke')
      app.update

      assert_equal false, received
    end
  end

  def test_rechecking_rewind_fires_true
    assert_tk_app("re-checking rewind fires callback with true") do
      require "gemba/settings_window"
      received = nil
      sw = Gemba::SettingsWindow.new(app, callbacks: {
        on_rewind_toggle: proc { |v| received = v }
      })
      sw.show
      app.update

      app.command(Gemba::Settings::VideoTab::REWIND_CHECK, 'invoke')
      app.update
      app.command(Gemba::Settings::VideoTab::REWIND_CHECK, 'invoke')
      app.update

      assert_equal true, received
    end
  end
end
