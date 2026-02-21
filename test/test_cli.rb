# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"

class TestCLI < Minitest::Test
  # -- subcommand dispatch --

  def test_subcommands_constant
    assert_includes Gemba::CLI::SUBCOMMANDS, 'play'
    assert_includes Gemba::CLI::SUBCOMMANDS, 'record'
    assert_includes Gemba::CLI::SUBCOMMANDS, 'decode'
    assert_includes Gemba::CLI::SUBCOMMANDS, 'replay'
    assert_includes Gemba::CLI::SUBCOMMANDS, 'config'
    assert_includes Gemba::CLI::SUBCOMMANDS, 'version'
    refute_includes Gemba::CLI::SUBCOMMANDS, 'info'
  end

  def test_main_help_lists_subcommands
    help = Gemba::CLI.main_help
    assert_includes help, "play"
    assert_includes help, "record"
    assert_includes help, "decode"
    assert_includes help, "replay"
    assert_includes help, "config"
    assert_includes help, "version"
  end

  def test_dry_run_main_help
    result = Gemba::CLI.run(["--help"], dry_run: true)
    assert_equal :help, result[:command]
  end
end
