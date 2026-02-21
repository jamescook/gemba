# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/cli/commands/play"

class TestCLIPlay < Minitest::Test
  Play = Gemba::CLI::Commands::Play
  # -- ROM argument --

  def test_rom_path
    assert_equal File.expand_path("game.gba"), play(["game.gba"]).parse[:rom]
  end

  def test_rom_path_expands_tilde
    assert_equal File.join(Dir.home, "game.gba"), play(["~/game.gba"]).parse[:rom]
  end

  def test_no_rom
    assert_nil play([]).parse[:rom]
  end

  # -- flags --

  def test_scale
    assert_equal 2, play(["--scale", "2"]).parse[:scale]
  end

  def test_scale_short
    assert_equal 3, play(["-s", "3"]).parse[:scale]
  end

  def test_scale_clamps_high
    assert_equal 4, play(["--scale", "10"]).parse[:scale]
  end

  def test_scale_clamps_low
    assert_equal 1, play(["--scale", "0"]).parse[:scale]
  end

  def test_volume
    assert_equal 50, play(["--volume", "50"]).parse[:volume]
  end

  def test_volume_short
    assert_equal 75, play(["-v", "75"]).parse[:volume]
  end

  def test_volume_clamps
    assert_equal 100, play(["--volume", "200"]).parse[:volume]
  end

  def test_mute
    assert play(["--mute"]).parse[:mute]
  end

  def test_mute_short
    assert play(["-m"]).parse[:mute]
  end

  def test_no_sound
    assert_equal false, play(["--no-sound"]).parse[:sound]
  end

  def test_fullscreen
    assert play(["--fullscreen"]).parse[:fullscreen]
  end

  def test_fullscreen_short
    assert play(["-f"]).parse[:fullscreen]
  end

  def test_show_fps
    assert play(["--show-fps"]).parse[:show_fps]
  end

  def test_turbo_speed
    assert_equal 3, play(["--turbo-speed", "3"]).parse[:turbo_speed]
  end

  def test_turbo_speed_clamps
    assert_equal 4, play(["--turbo-speed", "99"]).parse[:turbo_speed]
  end

  def test_locale
    assert_equal "ja", play(["--locale", "ja"]).parse[:locale]
  end

  def test_help_flag
    assert play(["--help"]).parse[:help]
  end

  def test_flags_with_rom
    opts = play(["-s", "2", "--mute", "pokemon.gba"]).parse
    assert_equal 2, opts[:scale]
    assert opts[:mute]
    assert_equal File.expand_path("pokemon.gba"), opts[:rom]
  end

  def test_rom_before_flags
    opts = play(["game.gba", "--scale", "4"]).parse
    assert_equal File.expand_path("game.gba"), opts[:rom]
    assert_equal 4, opts[:scale]
  end

  def test_parser_present
    assert_kind_of OptionParser, play([]).parse[:parser]
  end

  def test_help_output_includes_banner
    assert_includes play([]).parse[:parser].to_s, "Usage: gemba"
  end

  # -- apply --

  class MockConfig
    attr_accessor :scale, :volume, :muted, :show_fps, :turbo_speed, :locale

    def initialize
      @scale = 3
      @volume = 100
      @muted = false
      @show_fps = false
      @turbo_speed = 0
      @locale = 'auto'
    end
  end

  def test_apply_overrides_config
    config = MockConfig.new
    play([]).apply(config, { scale: 2, volume: 50, mute: true, show_fps: true })
    assert_equal 2, config.scale
    assert_equal 50, config.volume
    assert config.muted
    assert config.show_fps
  end

  def test_apply_skips_unset_options
    config = MockConfig.new
    play([]).apply(config, {})
    assert_equal 3, config.scale
    assert_equal 100, config.volume
    refute config.muted
  end

  def test_apply_locale
    config = MockConfig.new
    play([]).apply(config, { locale: 'ja' })
    assert_equal 'ja', config.locale
  end

  def test_apply_turbo_speed
    config = MockConfig.new
    play([]).apply(config, { turbo_speed: 3 })
    assert_equal 3, config.turbo_speed
  end

  # -- dry_run via CLI.run dispatch --

  def test_dry_run_no_args
    result = Gemba::CLI.run([], dry_run: true)
    assert_equal :play, result[:command]
    assert_nil result[:rom]
    assert_equal true, result[:sound]
  end

  def test_dry_run_with_rom
    result = Gemba::CLI.run(["game.gba"], dry_run: true)
    assert_equal :play, result[:command]
    assert_equal File.expand_path("game.gba"), result[:rom]
  end

  def test_dry_run_explicit_play
    result = Gemba::CLI.run(["play", "-s", "2", "game.gba"], dry_run: true)
    assert_equal :play, result[:command]
    assert_equal File.expand_path("game.gba"), result[:rom]
    assert_equal 2, result[:options][:scale]
  end

  def test_dry_run_no_sound
    result = Gemba::CLI.run(["--no-sound", "game.gba"], dry_run: true)
    assert_equal :play, result[:command]
    assert_equal false, result[:sound]
  end

  def test_dry_run_fullscreen
    result = Gemba::CLI.run(["-f", "game.gba"], dry_run: true)
    assert_equal :play, result[:command]
    assert_equal true, result[:fullscreen]
  end

  def test_dry_run_help
    result = Gemba::CLI.run(["play", "--help"], dry_run: true)
    assert_equal :play, result[:command]
    assert result[:help]
  end

  # -- error cases --

  def test_unknown_flag_raises
    assert_raises(OptionParser::InvalidOption) { play(["--bogus"]).parse }
  end

  def test_missing_scale_value_raises
    assert_raises(OptionParser::MissingArgument) { play(["--scale"]).parse }
  end

  private

  def play(argv)
    Play.new(argv)
  end
end
