# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "gemba/headless"

class TestConfigRA < Minitest::Test
  def setup
    @dir  = Dir.mktmpdir("gemba-ra-test")
    @path = File.join(@dir, "settings.json")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def new_config
    Gemba::Config.new(path: @path)
  end

  def test_defaults
    c = new_config
    refute c.ra_enabled?
    assert_equal '', c.ra_username
    assert_equal '', c.ra_token
    refute c.ra_hardcore?
  end

  def test_enabled_setter
    c = new_config
    c.ra_enabled = true
    assert c.ra_enabled?
    c.ra_enabled = false
    refute c.ra_enabled?
  end

  def test_username_setter
    c = new_config
    c.ra_username = 'alice'
    assert_equal 'alice', c.ra_username
  end

  def test_token_setter
    c = new_config
    c.ra_token = 'abc123'
    assert_equal 'abc123', c.ra_token
  end

  def test_hardcore_setter
    c = new_config
    c.ra_hardcore = true
    assert c.ra_hardcore?
  end

  def test_persistence_roundtrip
    c = new_config
    c.ra_enabled  = true
    c.ra_username = 'alice'
    c.ra_token    = 'secret'
    c.ra_hardcore = true
    c.save!

    c2 = new_config
    assert c2.ra_enabled?
    assert_equal 'alice',  c2.ra_username
    assert_equal 'secret', c2.ra_token
    assert c2.ra_hardcore?
  end
end
