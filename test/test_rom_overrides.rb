# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "gemba/config"
require "gemba/rom_overrides"

class TestRomOverrides < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir("rom_overrides_test")
    @json    = File.join(@tmpdir, "rom_overrides.json")
    @boxart  = File.join(@tmpdir, "boxart")
    # Point Config.boxart_dir at our tmpdir so copies land there
    @orig_env = ENV['GEMBA_CONFIG_DIR']
    ENV['GEMBA_CONFIG_DIR'] = @tmpdir
  end

  def teardown
    ENV['GEMBA_CONFIG_DIR'] = @orig_env
    FileUtils.rm_rf(@tmpdir)
  end

  def test_custom_boxart_returns_nil_when_nothing_set
    overrides = Gemba::RomOverrides.new(@json)
    assert_nil overrides.custom_boxart("AGB_AXVE-DEADBEEF")
  end

  def test_set_custom_boxart_copies_file_and_returns_dest
    src = File.join(@tmpdir, "cover.png")
    File.write(src, "fake png")

    overrides = Gemba::RomOverrides.new(@json)
    dest = overrides.set_custom_boxart("AGB_AXVE-DEADBEEF", src)

    assert File.exist?(dest), "Copied file should exist at dest"
    assert_equal "fake png", File.read(dest)
    assert_match %r{/AGB_AXVE-DEADBEEF/custom\.png$}, dest
  end

  def test_set_custom_boxart_persists_across_reload
    src = File.join(@tmpdir, "cover.png")
    File.write(src, "fake png")

    Gemba::RomOverrides.new(@json).set_custom_boxart("AGB_AXVE-DEADBEEF", src)

    reloaded = Gemba::RomOverrides.new(@json)
    stored   = reloaded.custom_boxart("AGB_AXVE-DEADBEEF")
    refute_nil stored
    assert File.exist?(stored)
  end

  def test_set_custom_boxart_preserves_extension
    src = File.join(@tmpdir, "cover.jpg")
    File.write(src, "fake jpg")

    overrides = Gemba::RomOverrides.new(@json)
    dest = overrides.set_custom_boxart("AGB_AXVE-DEADBEEF", src)

    assert dest.end_with?(".jpg"), "Extension should be preserved"
  end

  def test_multiple_rom_ids_stored_independently
    src1 = File.join(@tmpdir, "a.png"); File.write(src1, "a")
    src2 = File.join(@tmpdir, "b.png"); File.write(src2, "b")

    overrides = Gemba::RomOverrides.new(@json)
    overrides.set_custom_boxart("AGB_AXVE-AAAAAAAA", src1)
    overrides.set_custom_boxart("AGB_BPEE-BBBBBBBB", src2)

    assert_match %r{AAAAAAAA}, overrides.custom_boxart("AGB_AXVE-AAAAAAAA")
    assert_match %r{BBBBBBBB}, overrides.custom_boxart("AGB_BPEE-BBBBBBBB")
    assert_nil overrides.custom_boxart("AGB_ZZZZ-ZZZZZZZZ")
  end

  def test_json_file_is_valid_json
    src = File.join(@tmpdir, "cover.png")
    File.write(src, "fake")

    Gemba::RomOverrides.new(@json).set_custom_boxart("AGB_AXVE-DEADBEEF", src)

    parsed = JSON.parse(File.read(@json))
    assert_instance_of Hash, parsed
    assert parsed.key?("AGB_AXVE-DEADBEEF")
  end
end
