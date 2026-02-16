# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"

class TestXorDelta < Minitest::Test
  def test_xor_identical_strings_produces_zeros
    a = "\xFF\x00\xAB".b
    b = "\xFF\x00\xAB".b
    result = Gemba.xor_delta(a, b)
    assert_equal "\x00\x00\x00".b, result
  end

  def test_xor_against_zeros_returns_original
    a = "\xDE\xAD\xBE\xEF".b
    b = "\x00\x00\x00\x00".b
    result = Gemba.xor_delta(a, b)
    assert_equal a, result
  end

  def test_xor_is_reversible
    a = "hello world!".b
    b = "goodbye!!!12".b
    delta = Gemba.xor_delta(a, b)
    restored = Gemba.xor_delta(delta, b)
    assert_equal a, restored
  end

  def test_xor_mismatched_lengths_raises
    assert_raises(ArgumentError) do
      Gemba.xor_delta("abc", "ab")
    end
  end

  def test_xor_empty_strings
    result = Gemba.xor_delta("".b, "".b)
    assert_equal "".b, result
  end

  # -- count_changed_pixels --

  def test_count_all_zeros
    delta = "\x00\x00\x00\x00\x00\x00\x00\x00".b # 2 pixels, both zero
    assert_equal 0, Gemba.count_changed_pixels(delta)
  end

  def test_count_all_changed
    delta = "\xFF\x00\x00\x00\x00\xFF\x00\x00".b # 2 pixels, both non-zero
    assert_equal 2, Gemba.count_changed_pixels(delta)
  end

  def test_count_mixed
    # 3 pixels: changed, zero, changed
    delta = "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01".b
    assert_equal 2, Gemba.count_changed_pixels(delta)
  end

  def test_count_empty
    assert_equal 0, Gemba.count_changed_pixels("".b)
  end
end
