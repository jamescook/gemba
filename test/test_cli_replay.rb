# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/cli/commands/replay"

class TestCLIReplay < Minitest::Test
  Replay = Gemba::CLI::Commands::Replay
  # -- parse --

  def test_gir_file
    opts = rep(["session.gir"]).parse
    assert_equal "session.gir", opts[:gir]
  end

  def test_headless
    opts = rep(["--headless", "session.gir"]).parse
    assert opts[:headless]
  end

  def test_list
    opts = rep(["--list"]).parse
    assert opts[:list]
  end

  def test_fullscreen
    opts = rep(["-f", "session.gir"]).parse
    assert opts[:fullscreen]
  end

  def test_no_sound
    opts = rep(["--no-sound", "session.gir"]).parse
    assert_equal false, opts[:sound]
  end

  def test_help
    opts = rep(["--help"]).parse
    assert opts[:help]
  end

  # -- dry_run via CLI.run dispatch --

  def test_dry_run
    result = Gemba::CLI.run(["replay", "session.gir"], dry_run: true)
    assert_equal :replay, result[:command]
    assert_equal File.expand_path("session.gir"), result[:gir]
    assert_equal true, result[:sound]
  end

  def test_dry_run_headless
    result = Gemba::CLI.run(["replay", "--headless", "session.gir"], dry_run: true)
    assert_equal :replay_headless, result[:command]
    assert result[:headless]
  end

  def test_dry_run_list
    result = Gemba::CLI.run(["replay", "--list"], dry_run: true)
    assert_equal :replay_list, result[:command]
  end

  def test_dry_run_help
    result = Gemba::CLI.run(["replay", "--help"], dry_run: true)
    assert_equal :replay, result[:command]
    assert result[:help]
  end

  private

  def rep(argv)
    Replay.new(argv)
  end
end
