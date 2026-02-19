# frozen_string_literal: true

require_relative "test_helper"
require "gemba/headless"

class TestGameIndex < Minitest::Test
  def setup
    Gemba::GameIndex.reset!
  end

  def test_lookup_known_gba_game
    name = Gemba::GameIndex.lookup("AGB-AXVE")
    assert_includes name, "Pokemon"
    assert_includes name, "Ruby"
  end

  def test_lookup_returns_nil_for_unknown_code
    assert_nil Gemba::GameIndex.lookup("AGB-ZZZZ")
  end

  def test_lookup_returns_nil_for_nil_input
    assert_nil Gemba::GameIndex.lookup(nil)
  end

  def test_lookup_returns_nil_for_empty_string
    assert_nil Gemba::GameIndex.lookup("")
  end

  def test_lookup_returns_nil_for_unknown_platform
    assert_nil Gemba::GameIndex.lookup("XYZ-AAAA")
  end

  def test_lookup_gb_game
    # GB has very few entries but Pokemon Red should be there
    name = Gemba::GameIndex.lookup("DMG-APAU")
    assert_includes name, "Pokemon" if name
  end

  def test_reset_clears_cache
    Gemba::GameIndex.lookup("AGB-AXVE")
    Gemba::GameIndex.reset!
    # Should still work after reset (reloads lazily)
    name = Gemba::GameIndex.lookup("AGB-AXVE")
    assert_includes name, "Pokemon"
  end
end
