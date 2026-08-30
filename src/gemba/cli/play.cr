require "option_parser"
require "../main_window"

module Gemba
  module CLI
    # The default command: launch the GUI, optionally straight into a
    # ROM. Deliberately flag-light for now - ruby's play flags (--scale,
    # --volume, --mute...) mutate a config object the app then reads,
    # which this port's MainWindow doesn't yet take injected; they're
    # tracked as their own follow-up rather than half-wired here.
    class Play
      record Plan, rom : String?, help : Bool = false

      def initialize(@argv : Array(String), @dry_run : Bool = false, @io : IO = STDOUT)
      end

      def call : Plan
        help = false
        positionals = [] of String

        parser = OptionParser.new do |opts|
          opts.banner = <<-BANNER
            Usage: gemba [play] [ROM_FILE]

            Launch the GBA emulator. ROM_FILE is optional - without it the
            game picker opens, same as running gemba with no arguments.
            BANNER
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.unknown_args { |before_dash, after_dash| positionals = before_dash + after_dash }
          opts.invalid_option do |flag|
            @io.puts "gemba play: unknown option #{flag}"
            help = true
          end
        end
        parser.parse(@argv.dup)

        rom = positionals.first?.try { |path| File.expand_path(path) }

        if help
          @io.puts parser unless @dry_run
          return Plan.new(rom: rom, help: true)
        end

        plan = Plan.new(rom: rom)
        return plan if @dry_run

        window = MainWindow.new
        if rom_path = plan.rom
          window.load_rom(rom_path)
        end
        window.run
        plan
      end
    end
  end
end
