# frozen_string_literal: true

require "minitest/autorun"
require "gemba"

class TestMGBA < Minitest::Test
  def test_version_constant
    assert_match(/\A\d+\.\d+\.\d+\z/, Gemba::VERSION)
  end

  def test_module_structure
    assert_kind_of Module, Gemba
    assert_equal Class, Gemba::Core.class
  end

  def test_key_constants_are_unique_powers_of_two
    keys = %i[KEY_A KEY_B KEY_SELECT KEY_START
              KEY_RIGHT KEY_LEFT KEY_UP KEY_DOWN KEY_R KEY_L]

    values = keys.map { |k| Gemba.const_get(k) }
    assert_equal values.size, values.uniq.size, "all key constants should be unique"
    values.each do |v|
      assert_equal 0, v & (v - 1), "#{v} should be a power of 2"
    end
  end
end
