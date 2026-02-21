# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/cli/commands/decode"

class TestCLIDecode < Minitest::Test
  Decode = Gemba::CLI::Commands::Decode
  # -- parse --

  def test_grec_file
    opts = dec(["recording.grec"]).parse
    assert_equal "recording.grec", opts[:grec]
  end

  def test_output
    opts = dec(["-o", "out.mkv", "recording.grec"]).parse
    assert_equal "out.mkv", opts[:output]
  end

  def test_codecs
    opts = dec(["--video-codec", "libx265", "--audio-codec", "opus", "r.grec"]).parse
    assert_equal "libx265", opts[:video_codec]
    assert_equal "opus", opts[:audio_codec]
  end

  def test_stats
    opts = dec(["--stats", "recording.grec"]).parse
    assert opts[:stats]
    assert_equal "recording.grec", opts[:grec]
  end

  def test_list
    opts = dec(["--list"]).parse
    assert opts[:list]
  end

  def test_list_short
    opts = dec(["-l"]).parse
    assert opts[:list]
  end

  def test_no_progress
    opts = dec(["--no-progress", "r.grec"]).parse
    assert_equal false, opts[:progress]
  end

  def test_help
    opts = dec(["--help"]).parse
    assert opts[:help]
  end

  # -- dry_run via CLI.run dispatch --

  def test_dry_run_no_args_lists
    result = Gemba::CLI.run(["decode"], dry_run: true)
    assert_equal :decode_list, result[:command]
  end

  def test_dry_run
    result = Gemba::CLI.run(["decode", "recording.grec"], dry_run: true)
    assert_equal :decode, result[:command]
    assert_equal "recording.grec", result[:grec]
    refute result[:stats]
  end

  def test_dry_run_stats
    result = Gemba::CLI.run(["decode", "--stats", "recording.grec"], dry_run: true)
    assert_equal :decode_stats, result[:command]
    assert result[:stats]
    assert_equal "recording.grec", result[:grec]
  end

  def test_dry_run_with_codecs
    result = Gemba::CLI.run(["decode", "--video-codec", "libx265", "--audio-codec", "opus", "r.grec"], dry_run: true)
    assert_equal :decode, result[:command]
    assert_equal "libx265", result[:video_codec]
    assert_equal "opus", result[:audio_codec]
  end

  def test_dry_run_list
    result = Gemba::CLI.run(["decode", "--list"], dry_run: true)
    assert_equal :decode_list, result[:command]
  end

  def test_dry_run_help
    result = Gemba::CLI.run(["decode", "--help"], dry_run: true)
    assert_equal :decode, result[:command]
    assert result[:help]
  end

  private

  def dec(argv)
    Decode.new(argv)
  end
end
