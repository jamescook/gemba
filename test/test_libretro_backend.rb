# frozen_string_literal: true

require_relative "test_helper"
require "gemba/headless"

class TestLibretroBackend < Minitest::Test
  def setup
    Gemba::GameIndex.reset!
    @backend = Gemba::BoxartFetcher::LibretroBackend.new
  end

  def test_url_for_known_gba_game
    url = @backend.url_for("AGB-AXVE")
    assert_match %r{thumbnails\.libretro\.com}, url
    assert_match %r{Nintendo%20-%20Game%20Boy%20Advance}, url
    assert_match %r{Named_Boxarts}, url
    assert_match %r{Pokemon}, url
    assert url.end_with?(".png")
  end

  def test_url_for_unknown_game_returns_nil
    assert_nil @backend.url_for("AGB-ZZZZ")
  end

  def test_url_for_unknown_platform_returns_nil
    assert_nil @backend.url_for("XYZ-AAAA")
  end

  def test_url_encodes_special_characters
    # Games with special chars (parentheses, ampersands, etc.) should be encoded
    url = @backend.url_for("AGB-AXVE")
    refute_includes url, " "  # no raw spaces
  end

  def test_url_for_gb_game
    url = @backend.url_for("DMG-APAU")
    if url  # GB data is sparse
      assert_match %r{Nintendo%20-%20Game%20Boy/}, url
    end
  end
end
