# frozen_string_literal: true

require "minitest/autorun"
require "gemba"
require_relative "../lib/gemba/config"
require_relative "../lib/gemba/input_mappings"
require_relative "support/input_mocks"

class TestKeyboardMap < Minitest::Test
  def setup
    @config = MockInputConfig.new
    @map = Gemba::KeyboardMap.new(@config)
  end

  def test_default_labels
    labels = @map.labels
    assert_equal 'z', labels[:a]
    assert_equal 'x', labels[:b]
    assert_equal 'Return', labels[:start]
  end

  def test_set_remap
    @map.set(:a, 'q')
    assert_equal 'q', @map.labels[:a]
  end

  def test_set_removes_old_binding
    @map.set(:a, 'q')
    refute @map.labels.values.include?('z')
  end

  def test_set_unknown_button
    @map.set(:nonexistent, 'q')
    assert_equal 'z', @map.labels[:a]
  end

  def test_reset
    @map.set(:a, 'q')
    @map.reset!
    assert_equal 'z', @map.labels[:a]
  end

  def test_mask_no_device
    assert_equal 0, @map.mask
  end

  def test_mask_with_device
    kb = Gemba::VirtualKeyboard.new
    @map.device = kb
    kb.press('z')
    mask = @map.mask
    assert_equal Gemba::KEY_A, mask & Gemba::KEY_A
  end

  def test_mask_multiple_keys
    kb = Gemba::VirtualKeyboard.new
    @map.device = kb
    kb.press('z')
    kb.press('x')
    mask = @map.mask
    assert_equal Gemba::KEY_A, mask & Gemba::KEY_A
    assert_equal Gemba::KEY_B, mask & Gemba::KEY_B
  end

  def test_mask_released_key_not_in_mask
    kb = Gemba::VirtualKeyboard.new
    @map.device = kb
    kb.press('z')
    kb.release('z')
    assert_equal 0, @map.mask
  end

  def test_supports_deadzone
    refute @map.supports_deadzone?
  end

  def test_dead_zone_pct
    assert_equal 0, @map.dead_zone_pct
  end

  def test_set_dead_zone_raises
    assert_raises(NotImplementedError) { @map.set_dead_zone(100) }
  end

  def test_load_config
    cfg = MockInputConfig.new(keyboard_mappings: { 'a' => 'q', 'b' => 'w' })
    map = Gemba::KeyboardMap.new(cfg)
    assert_equal 'q', map.labels[:a]
    assert_equal 'w', map.labels[:b]
  end

  def test_reload
    @map.set(:a, 'q')
    @map.reload!
    assert @config.calls.any? { |c| c[0] == :reload! }
    # After reload with empty config, defaults restored
    assert_equal 'z', @map.labels[:a]
  end

  def test_save_to_config
    @map.save_to_config
    set_calls = @config.calls.select { |c| c[0] == :set_mapping }
    assert_equal 10, set_calls.size
    a_call = set_calls.find { |c| c[2] == :a }
    assert_equal 'keyboard', a_call[1]
    assert_equal 'z', a_call[3]
  end
end
