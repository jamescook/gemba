# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/cli/commands/record"

class TestCLIRecord < Minitest::Test
  Record = Gemba::CLI::Commands::Record
  # -- parse --

  def test_frames_and_rom
    opts = rec(["--frames", "100", "game.gba"]).parse
    assert_equal 100, opts[:frames]
    assert_equal File.expand_path("game.gba"), opts[:rom]
  end

  def test_output
    opts = rec(["-o", "out.grec", "--frames", "10", "game.gba"]).parse
    assert_equal "out.grec", opts[:output]
  end

  def test_compression
    opts = rec(["-c", "6", "--frames", "10", "game.gba"]).parse
    assert_equal 6, opts[:compression]
  end

  def test_compression_clamps
    opts = rec(["--compression", "99", "--frames", "10", "game.gba"]).parse
    assert_equal 9, opts[:compression]
  end

  def test_progress_flag
    opts = rec(["--progress", "--frames", "10", "game.gba"]).parse
    assert opts[:progress]
  end

  def test_help
    opts = rec(["--help"]).parse
    assert opts[:help]
  end

  # -- dry_run via CLI.run dispatch --

  def test_dry_run
    result = Gemba::CLI.run(["record", "--frames", "100", "game.gba"], dry_run: true)
    assert_equal :record, result[:command]
    assert_equal File.expand_path("game.gba"), result[:rom]
    assert_equal 100, result[:frames]
  end

  def test_dry_run_with_output
    result = Gemba::CLI.run(["record", "--frames", "50", "-o", "out.grec", "game.gba"], dry_run: true)
    assert_equal :record, result[:command]
    assert_equal "out.grec", result[:output]
    assert_equal 50, result[:frames]
  end

  def test_dry_run_help
    result = Gemba::CLI.run(["record", "--help"], dry_run: true)
    assert_equal :record, result[:command]
    assert result[:help]
  end

  private

  def rec(argv)
    Record.new(argv)
  end
end
