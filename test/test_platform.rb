# frozen_string_literal: true

require "minitest/autorun"
require "gemba/platform"

class TestPlatform < Minitest::Test
  # -- Factory ---------------------------------------------------------------

  def test_for_gba
    core = MockCore.new("GBA")
    platform = Gemba::Platform.for(core)
    assert_instance_of Gemba::Platform::GBA, platform
  end

  def test_for_gb
    core = MockCore.new("GB")
    platform = Gemba::Platform.for(core)
    assert_instance_of Gemba::Platform::GB, platform
  end

  def test_for_gbc
    core = MockCore.new("GBC")
    platform = Gemba::Platform.for(core)
    assert_instance_of Gemba::Platform::GBC, platform
  end

  def test_for_unknown_defaults_to_gb
    core = MockCore.new("Unknown")
    platform = Gemba::Platform.for(core)
    assert_instance_of Gemba::Platform::GB, platform
  end

  def test_default_is_gba
    platform = Gemba::Platform.default
    assert_instance_of Gemba::Platform::GBA, platform
  end

  # -- GBA -------------------------------------------------------------------

  def test_gba_resolution
    p = Gemba::Platform::GBA.new
    assert_equal 240, p.width
    assert_equal 160, p.height
  end

  def test_gba_fps
    p = Gemba::Platform::GBA.new
    assert_in_delta 59.7272, p.fps, 0.001
  end

  def test_gba_fps_fraction
    num, den = Gemba::Platform::GBA.new.fps_fraction
    assert_in_delta 59.7272, num.to_f / den, 0.001
  end

  def test_gba_aspect
    assert_equal [3, 2], Gemba::Platform::GBA.new.aspect
  end

  def test_gba_name
    assert_equal "Game Boy Advance", Gemba::Platform::GBA.new.name
    assert_equal "GBA", Gemba::Platform::GBA.new.short_name
  end

  def test_gba_buttons_include_lr
    buttons = Gemba::Platform::GBA.new.buttons
    assert_includes buttons, :l
    assert_includes buttons, :r
    assert_equal 10, buttons.size
  end

  def test_gba_thumb_size
    assert_equal [120, 80], Gemba::Platform::GBA.new.thumb_size
  end

  # -- GB --------------------------------------------------------------------

  def test_gb_resolution
    p = Gemba::Platform::GB.new
    assert_equal 160, p.width
    assert_equal 144, p.height
  end

  def test_gb_fps
    assert_in_delta 59.7275, Gemba::Platform::GB.new.fps, 0.001
  end

  def test_gb_fps_fraction
    num, den = Gemba::Platform::GB.new.fps_fraction
    assert_in_delta 59.7275, num.to_f / den, 0.001
  end

  def test_gb_aspect
    assert_equal [10, 9], Gemba::Platform::GB.new.aspect
  end

  def test_gb_name
    assert_equal "Game Boy", Gemba::Platform::GB.new.name
    assert_equal "GB", Gemba::Platform::GB.new.short_name
  end

  def test_gb_buttons_no_lr
    buttons = Gemba::Platform::GB.new.buttons
    refute_includes buttons, :l
    refute_includes buttons, :r
    assert_equal 8, buttons.size
  end

  def test_gb_thumb_size
    assert_equal [80, 72], Gemba::Platform::GB.new.thumb_size
  end

  # -- GBC -------------------------------------------------------------------

  def test_gbc_resolution_same_as_gb
    p = Gemba::Platform::GBC.new
    assert_equal 160, p.width
    assert_equal 144, p.height
  end

  def test_gbc_name_differs_from_gb
    assert_equal "Game Boy Color", Gemba::Platform::GBC.new.name
    assert_equal "GBC", Gemba::Platform::GBC.new.short_name
  end

  def test_gbc_buttons_no_lr
    buttons = Gemba::Platform::GBC.new.buttons
    refute_includes buttons, :l
    refute_includes buttons, :r
  end

  # -- Equality --------------------------------------------------------------

  def test_same_platform_equal
    assert_equal Gemba::Platform::GBA.new, Gemba::Platform::GBA.new
    assert_equal Gemba::Platform::GB.new, Gemba::Platform::GB.new
    assert_equal Gemba::Platform::GBC.new, Gemba::Platform::GBC.new
  end

  def test_different_platforms_not_equal
    refute_equal Gemba::Platform::GBA.new, Gemba::Platform::GB.new
    refute_equal Gemba::Platform::GBA.new, Gemba::Platform::GBC.new
    refute_equal Gemba::Platform::GB.new, Gemba::Platform::GBC.new
  end

  private

  MockCore = Struct.new(:platform)
end
