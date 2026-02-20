# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "gemba/headless"

class TestBios < Minitest::Test
  FAKE_BIOS = File.expand_path("fixtures/fake_bios.bin", __dir__)

  def setup
    @dir = Dir.mktmpdir("gemba-bios-test")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # -- exists? / valid? -------------------------------------------------------

  def test_exists_true_for_real_file
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    assert bios.exists?
  end

  def test_exists_false_for_missing_file
    bios = Gemba::Bios.new(path: File.join(@dir, "no_such.bin"))
    refute bios.exists?
  end

  def test_valid_for_correct_size
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    assert_equal Gemba::Bios::EXPECTED_SIZE, bios.size
    assert bios.valid?
  end

  def test_invalid_for_wrong_size
    path = File.join(@dir, "small.bin")
    File.binwrite(path, "\x00" * 100)
    bios = Gemba::Bios.new(path: path)
    refute bios.valid?
  end

  def test_invalid_for_missing_file
    bios = Gemba::Bios.new(path: File.join(@dir, "missing.bin"))
    refute bios.valid?
  end

  # -- filename ---------------------------------------------------------------

  def test_filename_returns_basename
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    assert_equal "fake_bios.bin", bios.filename
  end

  # -- checksum ---------------------------------------------------------------

  def test_checksum_nil_for_invalid_file
    bios = Gemba::Bios.new(path: File.join(@dir, "missing.bin"))
    assert_nil bios.checksum
  end

  def test_checksum_returns_integer_for_valid_file
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    assert_kind_of Integer, bios.checksum
  end

  def test_checksum_is_memoized
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    c1 = bios.checksum
    c2 = bios.checksum
    assert_equal c1, c2
    assert_same c1, c2  # same object, not just equal
  end

  # -- known? / official? / label ---------------------------------------------

  def test_fake_bios_is_not_official
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    refute bios.official?
    refute bios.ds_mode?
    refute bios.known?
  end

  def test_label_unknown_for_fake_bios
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    assert_equal "Unknown BIOS", bios.label
  end

  # -- status_text ------------------------------------------------------------

  def test_status_text_includes_size_for_valid_file
    bios = Gemba::Bios.new(path: FAKE_BIOS)
    assert_includes bios.status_text, "16384"
  end

  def test_status_text_not_found_for_missing_file
    bios = Gemba::Bios.new(path: File.join(@dir, "gone.bin"))
    assert_includes bios.status_text, "not found"
  end

  def test_status_text_invalid_size_for_wrong_size
    path = File.join(@dir, "wrong.bin")
    File.binwrite(path, "\x00" * 512)
    bios = Gemba::Bios.new(path: path)
    assert_includes bios.status_text, "Invalid size"
  end

  # -- from_config_name -------------------------------------------------------

  def test_from_config_name_nil_returns_nil
    assert_nil Gemba::Bios.from_config_name(nil)
  end

  def test_from_config_name_empty_returns_nil
    assert_nil Gemba::Bios.from_config_name("")
  end

  def test_from_config_name_builds_path_under_bios_dir
    bios = Gemba::Bios.from_config_name("gba_bios.bin")
    assert_equal File.join(Gemba::Config.bios_dir, "gba_bios.bin"), bios.path
  end
end
