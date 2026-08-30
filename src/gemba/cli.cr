require "./cli/play"
require "./cli/version_cmd"
require "./cli/config_cmd"
require "./cli/record"
require "./cli/decode"

module Gemba
  # gemba's command-line front door - a port of ruby gemba's CLI shell
  # (lib/gemba/cli.rb): a leading subcommand word picks a command class,
  # anything else defaults to `play` so `gemba` and `gemba rom.gba`
  # behave exactly as the bare app always has. Plain stdlib
  # OptionParser, same as ruby's optparse - no CLI framework.
  #
  # Every command runs IN this process - `play` blocks in Tk's mainloop
  # until the window closes, like any GUI app launched from a shell.
  # There is no launcher/child split (see the commands' own classes for
  # why the headless ones never touch Tk/SDL at runtime).
  #
  # dry_run: true parses and returns the typed execution Plan without
  # doing anything - what the specs assert on, and this port's stricter
  # version of ruby's execution-plan hashes.
  module CLI
    # All the names ruby gemba's CLI answers to, reserved up front even
    # where the command isn't ported yet - otherwise `gemba record`
    # would fall through to play and try to load a ROM literally named
    # "record", and implementing the command later would change what an
    # existing invocation does.
    SUBCOMMANDS = %w[play record decode replay config version patch ra]

    record HelpPlan, text : String
    record UnimplementedPlan, command : String

    alias Plan = HelpPlan | UnimplementedPlan | Play::Plan | VersionCmd::Plan | ConfigCmd::Plan |
                 Record::Plan | Decode::Plan

    # io/input/config_path/recordings_dir are spec seams (captured
    # output, scripted confirmation, isolated settings/recordings) -
    # production callers pass only argv.
    def self.run(argv : Array(String) = ARGV, dry_run : Bool = false,
                 io : IO = STDOUT, input : IO = STDIN,
                 config_path : String = Config.path,
                 recordings_dir : String = Paths.recordings_dir) : Plan
      args = argv.dup

      if args.first? == "--help" || args.first? == "-h"
        io.puts main_help unless dry_run
        return HelpPlan.new(text: main_help)
      end

      command = SUBCOMMANDS.includes?(args.first?) ? args.shift : "play"

      case command
      when "play"    then Play.new(args, dry_run: dry_run, io: io).call
      when "version" then VersionCmd.new(dry_run: dry_run, io: io).call
      when "config"  then ConfigCmd.new(args, dry_run: dry_run, io: io, input: input, config_path: config_path).call
      when "record"  then Record.new(args, dry_run: dry_run, io: io).call
      when "decode"  then Decode.new(args, dry_run: dry_run, io: io, recordings_dir: recordings_dir).call
      else
        io.puts "gemba #{command} is not implemented yet" unless dry_run
        UnimplementedPlan.new(command: command)
      end
    end

    # 1.5 GB / 12.3 MB / 640.0 KB - ruby's format_size, shared by the
    # record/decode reports.
    def self.format_size(bytes : Int) : String
      if bytes >= 1_073_741_824
        sprintf("%.1f GB", bytes / 1_073_741_824.0)
      elsif bytes >= 1_048_576
        sprintf("%.1f MB", bytes / 1_048_576.0)
      else
        sprintf("%.1f KB", bytes / 1024.0)
      end
    end

    def self.main_help : String
      <<-HELP
        Usage: gemba [command] [options]

        GBA emulator powered by tryst + libmgba

        Commands:
          play      Play a ROM (default)
          record    Record video+audio to .grec (headless)
          decode    Encode .grec to video via ffmpeg (--stats for info)
          replay    Replay a .gir input recording
          patch     Apply an IPS/BPS/UPS patch to a ROM
          config    Show or reset configuration
          version   Show version
          ra        RetroAchievements - login, verify, achievements

        Run 'gemba <command> --help' for command-specific options.
        HELP
    end
  end
end
