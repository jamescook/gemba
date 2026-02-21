# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    SUBCOMMANDS = %w[play record decode replay config version patch ra].freeze

    # Entry point: dispatch to subcommand or default to play.
    # @param argv [Array<String>]
    # @param dry_run [Boolean] parse and validate only, return execution plan
    def self.run(argv = ARGV, dry_run: false)
      args = argv.dup

      if args.first == '--help' || args.first == '-h'
        puts main_help unless dry_run
        return { command: :help }
      end

      cmd = SUBCOMMANDS.include?(args.first) ? args.shift : 'play'

      case cmd
      when 'play'
        require 'gemba/cli/commands/play'
        Commands::Play.new(args, dry_run: dry_run).call
      when 'record'
        require 'gemba/cli/commands/record'
        Commands::Record.new(args, dry_run: dry_run).call
      when 'decode'
        require 'gemba/cli/commands/decode'
        Commands::Decode.new(args, dry_run: dry_run).call
      when 'replay'
        require 'gemba/cli/commands/replay'
        Commands::Replay.new(args, dry_run: dry_run).call
      when 'config'
        require 'gemba/cli/commands/config_cmd'
        Commands::ConfigCmd.new(args, dry_run: dry_run).call
      when 'version'
        require 'gemba/cli/commands/version'
        Commands::Version.new(args, dry_run: dry_run).call
      when 'patch'
        require 'gemba/cli/commands/patch'
        Commands::Patch.new(args, dry_run: dry_run).call
      when 'ra'
        require 'gemba/cli/commands/retro_achievements'
        Commands::RetroAchievements.new(args, dry_run: dry_run).call
      end
    end

    # Main help text listing all subcommands.
    def self.main_help
      <<~HELP
        Usage: gemba [command] [options]

        GBA emulator powered by teek + libmgba

        Commands:
          play      Play a ROM (default)
          record    Record video+audio to .grec (headless)
          decode    Encode .grec to video via ffmpeg (--stats for info)
          replay    Replay a .gir input recording
          patch     Apply an IPS/BPS/UPS patch to a ROM
          config    Show or reset configuration
          version   Show version
          ra        RetroAchievements — login, verify, achievements

        Run 'gemba <command> --help' for command-specific options.
      HELP
    end

  end
end
