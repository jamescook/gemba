# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/cli/commands/config_cmd"

class TestCLIConfig < Minitest::Test
  ConfigCmd = Gemba::CLI::Commands::ConfigCmd

  # -- parse --

  def test_reset_flag
    assert cfg(["--reset"]).parse[:reset]
  end

  def test_reset_with_yes
    opts = cfg(["--reset", "-y"]).parse
    assert opts[:reset]
    assert opts[:yes]
  end

  def test_help
    assert cfg(["--help"]).parse[:help]
  end

  def test_no_flags
    opts = cfg([]).parse
    refute opts[:reset]
    refute opts[:help]
  end

  # -- dry_run via CLI.run dispatch --

  def test_dry_run_show
    result = Gemba::CLI.run(["config"], dry_run: true)
    assert_equal :config_show, result[:command]
    refute result[:reset]
  end

  def test_dry_run_reset
    result = Gemba::CLI.run(["config", "--reset"], dry_run: true)
    assert_equal :config_reset, result[:command]
    assert result[:reset]
  end

  def test_dry_run_reset_yes
    result = Gemba::CLI.run(["config", "--reset", "-y"], dry_run: true)
    assert_equal :config_reset, result[:command]
    assert result[:reset]
    assert result[:yes]
  end

  def test_dry_run_help
    result = Gemba::CLI.run(["config", "--help"], dry_run: true)
    assert_equal :config, result[:command]
    assert result[:help]
  end

  private

  def cfg(argv)
    ConfigCmd.new(argv)
  end
end
