# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/cli/commands/patch"

class TestCLIPatch < Minitest::Test
  Patch = Gemba::CLI::Commands::Patch

  # -- parse --

  def test_rom_and_patch_args
    opts = pat(["game.gba", "fix.ips"]).parse
    assert_equal File.expand_path("game.gba"), opts[:rom]
    assert_equal File.expand_path("fix.ips"),  opts[:patch]
  end

  def test_output_flag
    opts = pat(["-o", "/tmp/out.gba", "game.gba", "fix.ips"]).parse
    assert_equal File.expand_path("/tmp/out.gba"), opts[:output]
  end

  def test_help
    assert pat(["--help"]).parse[:help]
  end

  def test_missing_args_returns_error
    result = pat([]).call
    assert_equal :patch, result[:command]
    assert_equal :missing_args, result[:error]
  end

  # -- dry_run via CLI.run dispatch --

  def test_dry_run
    result = Gemba::CLI.run(["patch", "game.gba", "fix.ips"], dry_run: true)
    assert_equal :patch, result[:command]
    assert_equal File.expand_path("game.gba"), result[:rom]
    assert_equal File.expand_path("fix.ips"),  result[:patch]
  end

  def test_dry_run_default_out_path
    result = Gemba::CLI.run(["patch", "game.gba", "fix.ips"], dry_run: true)
    assert_match(/-patched\.gba\z/, result[:out])
  end

  def test_dry_run_help
    result = Gemba::CLI.run(["patch", "--help"], dry_run: true)
    assert_equal :patch, result[:command]
    assert result[:help]
  end

  private

  def pat(argv)
    Patch.new(argv)
  end
end
