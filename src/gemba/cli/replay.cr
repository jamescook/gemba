require "option_parser"
require "../core"
require "../input_replayer"
require "../paths"
require "../main_window"

module Gemba
  module CLI
    # `gemba replay session.gir` - play back a .gir input recording.
    #
    # GUI mode (the default) launches the app with the replay viewer
    # open - the same MainWindow#open_replay/ReplayWindow path the View
    # menu uses; ruby's standalone ReplayPlayer window has no crystal
    # equivalent and doesn't need one. --headless drives a bare Core
    # through InputReplayer as fast as it runs and prints a summary -
    # the same driver everywhere, per the .gir format's whole point.
    #
    # The ROM comes from the .gir header; a second positional overrides
    # it (headless mode only, same as ruby - the GUI path trusts the
    # header).
    class Replay
      record Plan,
        gir : String? = nil, rom : String? = nil,
        headless : Bool = false, progress : Bool = false,
        list : Bool = false, help : Bool = false, error : String? = nil

      def initialize(@argv : Array(String), @dry_run : Bool = false,
                     @io : IO = STDOUT, @err : IO = STDERR,
                     @recordings_dir : String = Paths.recordings_dir)
      end

      def call : Plan
        plan = parse

        if plan.help
          @io.puts @parser unless @dry_run
          return plan
        end

        if plan.list
          list_recordings unless @dry_run
          return plan
        end

        if error = plan.error
          raise Error.new("#{error}\nRun 'gemba replay --help' for usage") unless @dry_run
          return plan
        end
        return plan if @dry_run

        plan.headless ? run_headless(plan) : run_gui(plan)
        plan
      end

      private def parse : Plan
        headless = false
        progress = false
        list = false
        help = false
        positionals = [] of String

        parser = OptionParser.new do |opts|
          opts.banner = <<-BANNER
            Usage: gemba replay [options] GIR_FILE [ROM_FILE]

            Replay a .gir input recording.
            ROM is read from the .gir header; override with ROM_FILE (headless only).
            BANNER
          opts.on("-l", "--list", "List available .gir recordings") { list = true }
          opts.on("--headless", "Run without GUI (print summary and exit)") { headless = true }
          opts.on("--progress", "Show progress (headless only)") { progress = true }
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.unknown_args { |before_dash, after_dash| positionals = before_dash + after_dash }
          opts.invalid_option do |flag|
            @io.puts "gemba replay: unknown option #{flag}"
            help = true
          end
        end
        @parser = parser
        parser.parse(@argv.dup)

        gir = positionals[0]?.try { |path| File.expand_path(path) }
        rom = positionals[1]?.try { |path| File.expand_path(path) }
        error = gir || help || list ? nil : "replay requires a .gir file"
        Plan.new(gir: gir, rom: rom, headless: headless, progress: progress,
          list: list, help: help, error: error)
      end

      private def run_headless(plan : Plan) : Nil
        gir = plan.gir.as(String)
        replayer = InputReplayer.new(gir)
        rom = plan.rom || replayer.rom_path ||
              raise Error.new(".gir has no rom_path in header; pass ROM_FILE explicitly")
        rom = File.expand_path(rom)
        raise Error.new("ROM not found: #{rom}") unless File.exists?(rom)

        core = Core.new(rom)
        begin
          begin
            replayer.validate!(core)
          rescue ex : InputReplayer::ChecksumMismatch
            raise Error.new(ex.message.to_s)
          end
          unless core.load_state_from_file(replayer.anchor_state_path)
            raise Error.new("cannot load anchor state: #{replayer.anchor_state_path}")
          end

          drive(core, replayer, plan.progress)
          @io.puts "Replayed #{gir} (#{replayer.frame_count} frames)"
        ensure
          core.destroy
        end
      end

      private def drive(core : Core, replayer : InputReplayer, progress : Bool) : Nil
        total = replayer.frame_count
        last_print = Time.instant - 1.seconds

        replayer.each_bitmask do |mask, idx|
          core.keys = mask
          core.run_frame
          next unless progress

          frame = idx + 1
          now = Time.instant
          if frame == total || now - last_print >= 0.5.seconds
            @err.print sprintf("\rReplaying: %d/%d (%.1f%%)\e[K", frame, total, frame * 100.0 / total)
            last_print = now
          end
        end
        @err.print "\r\e[K" if progress
      end

      private def run_gui(plan : Plan) : Nil
        window = MainWindow.new
        window.open_replay(plan.gir.as(String))
        window.run
      end

      # Grouped by the header's game code, ruby-style.
      private def list_recordings : Nil
        unless Dir.exists?(@recordings_dir)
          @io.puts "No recordings directory found at #{@recordings_dir}"
          return
        end

        paths = Dir.glob(File.join(@recordings_dir, "*.gir")).sort!
        if paths.empty?
          @io.puts "No .gir recordings in #{@recordings_dir}"
          return
        end

        by_game = {} of String => Array({String, Int32})
        paths.each do |path|
          replayer = InputReplayer.new(path)
          key = replayer.game_code || "unknown"
          (by_game[key] ||= [] of {String, Int32}) << {path, replayer.frame_count}
        end

        by_game.each do |game_code, entries|
          @io.puts "#{game_code}:"
          entries.each { |entry| @io.puts "  #{entry[0]}  (#{entry[1]} frames)" }
        end
      end

      @parser : OptionParser?
    end
  end
end
