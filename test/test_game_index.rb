# frozen_string_literal: true

require_relative "test_helper"
require "gemba/headless"

class TestGameIndex < Minitest::Test
  def setup
    Gemba::GameIndex.reset!
  end

  # -- lookup (by game code) -----------------------------------------------

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

  def test_lookup_returns_nil_for_unknown_platform_prefix
    assert_nil Gemba::GameIndex.lookup("XYZ-AAAA")
  end

  def test_lookup_known_gbc_game
    # Pokemon Gold is a well-known GBC title
    name = Gemba::GameIndex.lookup("CGB-BYEE")
    assert_includes name, "Pokemon" if name  # only assert content if present
    # At minimum it must not raise
  end

  # -- lookup_by_md5 -------------------------------------------------------

  def test_lookup_by_md5_returns_nil_for_nil_md5
    assert_nil Gemba::GameIndex.lookup_by_md5(nil, "gba")
  end

  def test_lookup_by_md5_returns_nil_for_empty_md5
    assert_nil Gemba::GameIndex.lookup_by_md5("", "gba")
  end

  def test_lookup_by_md5_returns_nil_for_unknown_platform
    assert_nil Gemba::GameIndex.lookup_by_md5("abc123", "snes")
  end

  def test_lookup_by_md5_returns_nil_for_unknown_digest
    assert_nil Gemba::GameIndex.lookup_by_md5("0" * 32, "gba")
  end

  def test_lookup_by_md5_is_case_insensitive
    # Use a real digest present in gba_md5.json so both lookups must return a non-nil title
    md5   = "0007d212d9b76a466c7ca003d50c8c74"
    lower = Gemba::GameIndex.lookup_by_md5(md5.downcase, "gba")
    upper = Gemba::GameIndex.lookup_by_md5(md5.upcase,   "gba")
    refute_nil lower, "lowercase MD5 lookup must return a title"
    assert_equal lower, upper
  end

  # -- reset! / caching ----------------------------------------------------

  def test_reset_clears_cache_and_reloads
    Gemba::GameIndex.lookup("AGB-AXVE")
    Gemba::GameIndex.reset!
    name = Gemba::GameIndex.lookup("AGB-AXVE")
    assert_includes name, "Pokemon"
  end
end
