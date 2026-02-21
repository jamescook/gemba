# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/cli/commands/version"

class TestCLIVersion < Minitest::Test
  Version = Gemba::CLI::Commands::Version

  def test_dry_run_returns_version
    result = Version.new([], dry_run: true).call
    assert_equal :version, result[:command]
    assert_equal Gemba::VERSION, result[:version]
  end

  def test_prints_version
    out = capture_io { Version.new([]).call }[0]
    assert_includes out, "gemba"
    assert_includes out, Gemba::VERSION
  end

  def test_dry_run_via_dispatch
    result = Gemba::CLI.run(["version"], dry_run: true)
    assert_equal :version, result[:command]
    assert_equal Gemba::VERSION, result[:version]
  end
end
