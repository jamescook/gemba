# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"

class TestCLI < Minitest::Test
  def parse_play(args)
    Gemba::CLI.parse_play(args)
  end

  # -- ROM argument --

  def test_rom_path
    opts = parse_play(["game.gba"])
    assert_equal File.expand_path("game.gba"), opts[:rom]
  end

  def test_rom_path_expands_tilde
    opts = parse_play(["~/game.gba"])
    assert_equal File.join(Dir.home, "game.gba"), opts[:rom]
  end

  def test_no_rom
    opts = parse_play([])
    assert_nil opts[:rom]
  end

  # -- play flags --

  def test_scale
    opts = parse_play(["--scale", "2"])
    assert_equal 2, opts[:scale]
  end

  def test_scale_short
    opts = parse_play(["-s", "3"])
    assert_equal 3, opts[:scale]
  end

  def test_scale_clamps_high
    opts = parse_play(["--scale", "10"])
    assert_equal 4, opts[:scale]
  end

  def test_scale_clamps_low
    opts = parse_play(["--scale", "0"])
    assert_equal 1, opts[:scale]
  end

  def test_volume
    opts = parse_play(["--volume", "50"])
    assert_equal 50, opts[:volume]
  end

  def test_volume_short
    opts = parse_play(["-v", "75"])
    assert_equal 75, opts[:volume]
  end

  def test_volume_clamps
    opts = parse_play(["--volume", "200"])
    assert_equal 100, opts[:volume]
  end

  def test_mute
    opts = parse_play(["--mute"])
    assert opts[:mute]
  end

  def test_mute_short
    opts = parse_play(["-m"])
    assert opts[:mute]
  end

  def test_no_sound
    opts = parse_play(["--no-sound"])
    assert_equal false, opts[:sound]
  end

  def test_fullscreen
    opts = parse_play(["--fullscreen"])
    assert opts[:fullscreen]
  end

  def test_fullscreen_short
    opts = parse_play(["-f"])
    assert opts[:fullscreen]
  end

  def test_show_fps
    opts = parse_play(["--show-fps"])
    assert opts[:show_fps]
  end

  def test_turbo_speed
    opts = parse_play(["--turbo-speed", "3"])
    assert_equal 3, opts[:turbo_speed]
  end

  def test_turbo_speed_clamps
    opts = parse_play(["--turbo-speed", "99"])
    assert_equal 4, opts[:turbo_speed]
  end

  def test_locale
    opts = parse_play(["--locale", "ja"])
    assert_equal "ja", opts[:locale]
  end

  def test_help_flag
    opts = parse_play(["--help"])
    assert opts[:help]
  end

  # -- combinations --

  def test_flags_with_rom
    opts = parse_play(["-s", "2", "--mute", "pokemon.gba"])
    assert_equal 2, opts[:scale]
    assert opts[:mute]
    assert_equal File.expand_path("pokemon.gba"), opts[:rom]
  end

  def test_rom_before_flags
    opts = parse_play(["game.gba", "--scale", "4"])
    assert_equal File.expand_path("game.gba"), opts[:rom]
    assert_equal 4, opts[:scale]
  end

  # -- parser included for help output --

  def test_parser_present
    opts = parse_play([])
    assert_kind_of OptionParser, opts[:parser]
  end

  def test_help_output_includes_banner
    opts = parse_play([])
    help = opts[:parser].to_s
    assert_includes help, "Usage: gemba"
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
    Gemba::CLI.apply(config, { scale: 2, volume: 50, mute: true, show_fps: true })
    assert_equal 2, config.scale
    assert_equal 50, config.volume
    assert config.muted
    assert config.show_fps
  end

  def test_apply_skips_unset_options
    config = MockConfig.new
    Gemba::CLI.apply(config, {})
    assert_equal 3, config.scale
    assert_equal 100, config.volume
    refute config.muted
  end

  def test_apply_locale
    config = MockConfig.new
    Gemba::CLI.apply(config, { locale: 'ja' })
    assert_equal 'ja', config.locale
  end

  def test_apply_turbo_speed
    config = MockConfig.new
    Gemba::CLI.apply(config, { turbo_speed: 3 })
    assert_equal 3, config.turbo_speed
  end

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

  # -- record subcommand parsing --

  def test_parse_record_frames_and_rom
    opts = Gemba::CLI.parse_record(["--frames", "100", "game.gba"])
    assert_equal 100, opts[:frames]
    assert_equal File.expand_path("game.gba"), opts[:rom]
  end

  def test_parse_record_output
    opts = Gemba::CLI.parse_record(["-o", "out.grec", "--frames", "10", "game.gba"])
    assert_equal "out.grec", opts[:output]
  end

  def test_parse_record_help
    opts = Gemba::CLI.parse_record(["--help"])
    assert opts[:help]
  end

  # -- decode subcommand parsing --

  def test_parse_decode_grec
    opts = Gemba::CLI.parse_decode(["recording.grec"])
    assert_equal "recording.grec", opts[:grec]
  end

  def test_parse_decode_output
    opts = Gemba::CLI.parse_decode(["-o", "out.mkv", "recording.grec"])
    assert_equal "out.mkv", opts[:output]
  end

  def test_parse_decode_codecs
    opts = Gemba::CLI.parse_decode(["--video-codec", "libx265", "--audio-codec", "opus", "r.grec"])
    assert_equal "libx265", opts[:video_codec]
    assert_equal "opus", opts[:audio_codec]
  end

  def test_parse_decode_stats
    opts = Gemba::CLI.parse_decode(["--stats", "recording.grec"])
    assert opts[:stats]
    assert_equal "recording.grec", opts[:grec]
  end

  def test_parse_decode_list
    opts = Gemba::CLI.parse_decode(["--list"])
    assert opts[:list]
  end

  def test_parse_decode_list_short
    opts = Gemba::CLI.parse_decode(["-l"])
    assert opts[:list]
  end

  # -- replay subcommand parsing --

  def test_parse_replay_gir
    opts = Gemba::CLI.parse_replay(["session.gir"])
    assert_equal "session.gir", opts[:gir]
  end

  def test_parse_replay_headless
    opts = Gemba::CLI.parse_replay(["--headless", "session.gir"])
    assert opts[:headless]
  end

  def test_parse_replay_list
    opts = Gemba::CLI.parse_replay(["--list"])
    assert opts[:list]
  end

  def test_parse_replay_fullscreen
    opts = Gemba::CLI.parse_replay(["-f", "session.gir"])
    assert opts[:fullscreen]
  end

  def test_parse_replay_no_sound
    opts = Gemba::CLI.parse_replay(["--no-sound", "session.gir"])
    assert_equal false, opts[:sound]
  end

  def test_parse_replay_help
    opts = Gemba::CLI.parse_replay(["--help"])
    assert opts[:help]
  end

  # -- config subcommand parsing --

  def test_parse_config_reset
    opts = Gemba::CLI.parse_config(["--reset"])
    assert opts[:reset]
  end

  def test_parse_config_reset_with_yes
    opts = Gemba::CLI.parse_config(["--reset", "-y"])
    assert opts[:reset]
    assert opts[:yes]
  end

  def test_parse_config_help
    opts = Gemba::CLI.parse_config(["--help"])
    assert opts[:help]
  end

  def test_parse_config_no_flags
    opts = Gemba::CLI.parse_config([])
    refute opts[:reset]
    refute opts[:help]
  end

  # -- version --

  def test_run_version
    out = capture_io { Gemba::CLI.run_version([]) }[0]
    assert_includes out, "gemba"
    assert_includes out, Gemba::VERSION
  end

  # -- dry_run: full dispatch pipeline --

  def test_dry_run_play_no_args
    result = Gemba::CLI.run([], dry_run: true)
    assert_equal :play, result[:command]
    assert_nil result[:rom]
    assert_equal true, result[:sound]
  end

  def test_dry_run_play_with_rom
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

  def test_dry_run_play_no_sound
    result = Gemba::CLI.run(["--no-sound", "game.gba"], dry_run: true)
    assert_equal :play, result[:command]
    assert_equal false, result[:sound]
  end

  def test_dry_run_play_fullscreen
    result = Gemba::CLI.run(["-f", "game.gba"], dry_run: true)
    assert_equal :play, result[:command]
    assert_equal true, result[:fullscreen]
  end

  def test_dry_run_play_help
    result = Gemba::CLI.run(["play", "--help"], dry_run: true)
    assert_equal :play, result[:command]
    assert result[:help]
  end

  def test_dry_run_record
    result = Gemba::CLI.run(["record", "--frames", "100", "game.gba"], dry_run: true)
    assert_equal :record, result[:command]
    assert_equal File.expand_path("game.gba"), result[:rom]
    assert_equal 100, result[:frames]
  end

  def test_dry_run_record_with_output
    result = Gemba::CLI.run(["record", "--frames", "50", "-o", "out.grec", "game.gba"], dry_run: true)
    assert_equal :record, result[:command]
    assert_equal "out.grec", result[:output]
    assert_equal 50, result[:frames]
  end

  def test_dry_run_record_help
    result = Gemba::CLI.run(["record", "--help"], dry_run: true)
    assert_equal :record, result[:command]
    assert result[:help]
  end

  def test_dry_run_decode_no_args_lists
    result = Gemba::CLI.run(["decode"], dry_run: true)
    assert_equal :decode_list, result[:command]
  end

  def test_dry_run_decode
    result = Gemba::CLI.run(["decode", "recording.grec"], dry_run: true)
    assert_equal :decode, result[:command]
    assert_equal "recording.grec", result[:grec]
    refute result[:stats]
  end

  def test_dry_run_decode_stats
    result = Gemba::CLI.run(["decode", "--stats", "recording.grec"], dry_run: true)
    assert_equal :decode_stats, result[:command]
    assert result[:stats]
    assert_equal "recording.grec", result[:grec]
  end

  def test_dry_run_decode_with_codecs
    result = Gemba::CLI.run(["decode", "--video-codec", "libx265", "--audio-codec", "opus", "r.grec"], dry_run: true)
    assert_equal :decode, result[:command]
    assert_equal "libx265", result[:video_codec]
    assert_equal "opus", result[:audio_codec]
  end

  def test_dry_run_decode_list
    result = Gemba::CLI.run(["decode", "--list"], dry_run: true)
    assert_equal :decode_list, result[:command]
  end

  def test_dry_run_decode_help
    result = Gemba::CLI.run(["decode", "--help"], dry_run: true)
    assert_equal :decode, result[:command]
    assert result[:help]
  end

  def test_dry_run_replay
    result = Gemba::CLI.run(["replay", "session.gir"], dry_run: true)
    assert_equal :replay, result[:command]
    assert_equal File.expand_path("session.gir"), result[:gir]
    assert_equal true, result[:sound]
  end

  def test_dry_run_replay_headless
    result = Gemba::CLI.run(["replay", "--headless", "session.gir"], dry_run: true)
    assert_equal :replay_headless, result[:command]
    assert result[:headless]
  end

  def test_dry_run_replay_list
    result = Gemba::CLI.run(["replay", "--list"], dry_run: true)
    assert_equal :replay_list, result[:command]
  end

  def test_dry_run_replay_help
    result = Gemba::CLI.run(["replay", "--help"], dry_run: true)
    assert_equal :replay, result[:command]
    assert result[:help]
  end

  def test_dry_run_config_show
    result = Gemba::CLI.run(["config"], dry_run: true)
    assert_equal :config_show, result[:command]
    refute result[:reset]
  end

  def test_dry_run_config_reset
    result = Gemba::CLI.run(["config", "--reset"], dry_run: true)
    assert_equal :config_reset, result[:command]
    assert result[:reset]
  end

  def test_dry_run_config_reset_yes
    result = Gemba::CLI.run(["config", "--reset", "-y"], dry_run: true)
    assert_equal :config_reset, result[:command]
    assert result[:reset]
    assert result[:yes]
  end

  def test_dry_run_config_help
    result = Gemba::CLI.run(["config", "--help"], dry_run: true)
    assert_equal :config, result[:command]
    assert result[:help]
  end

  def test_dry_run_version
    result = Gemba::CLI.run(["version"], dry_run: true)
    assert_equal :version, result[:command]
    assert_equal Gemba::VERSION, result[:version]
  end

  def test_dry_run_main_help
    result = Gemba::CLI.run(["--help"], dry_run: true)
    assert_equal :help, result[:command]
  end

  # -- error cases --

  def test_unknown_play_flag_raises
    assert_raises(OptionParser::InvalidOption) { parse_play(["--bogus"]) }
  end

  def test_missing_scale_value_raises
    assert_raises(OptionParser::MissingArgument) { parse_play(["--scale"]) }
  end
end
