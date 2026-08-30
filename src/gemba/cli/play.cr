require "option_parser"
require "../main_window"
require "../config"

module Gemba
  module CLI
    # The default command: launch the GUI, optionally straight into a
    # ROM, with ruby play.rb's session-only flag overrides - applied to
    # an in-memory Config handed to MainWindow, never save!d, so a
    # `--mute` today doesn't become the persisted default tomorrow
    # (ruby's user_config semantics exactly).
    #
    # Only the flags with a real knob in this port are here; ruby's
    # --turbo-speed/--bios/--no-sound have no crystal Config equivalent
    # yet and come with the features that need them.
    class Play
      record Plan,
        rom : String? = nil, scale : Int32? = nil, volume : Int32? = nil,
        mute : Bool = false, show_fps : Bool = false, fullscreen : Bool = false,
        locale : String? = nil, help : Bool = false

      def initialize(@argv : Array(String), @dry_run : Bool = false, @io : IO = STDOUT)
      end

      def call : Plan
        plan = parse

        if plan.help
          @io.puts @parser unless @dry_run
          return plan
        end
        return plan if @dry_run

        config = Config.new
        Play.apply(config, plan)
        window = MainWindow.new(config: config)
        if rom = plan.rom
          window.load_rom(rom)
        end
        window.app.window.set_attribute("-fullscreen", true) if plan.fullscreen
        window.run
        plan
      end

      # Writes the flag overrides into config IN MEMORY - deliberately
      # no save!, see the class comment. Public so a spec can assert
      # both the application and the not-persisting without a window.
      def self.apply(config : Config, plan : Plan) : Nil
        if scale = plan.scale
          config.scale = scale
        end
        if volume = plan.volume
          config.volume = volume
        end
        config.muted = true if plan.mute
        config.show_fps = true if plan.show_fps
        if locale = plan.locale
          config.locale = locale
        end
      end

      private def parse : Plan
        scale = nil.as(Int32?)
        volume = nil.as(Int32?)
        mute = false
        show_fps = false
        fullscreen = false
        locale = nil.as(String?)
        help = false
        positionals = [] of String

        parser = OptionParser.new do |opts|
          opts.banner = <<-BANNER
            Usage: gemba [play] [options] [ROM_FILE]

            Launch the GBA emulator. ROM_FILE is optional - without it the
            game picker opens. Flags override saved settings for this
            session only; they are not persisted.
            BANNER
          opts.on("-s N", "--scale N", "Window scale (1-4)") { |value| scale = (value.to_i? || 3).clamp(1, 4) }
          opts.on("-v N", "--volume N", "Volume (0-100)") { |value| volume = (value.to_i? || 100).clamp(0, 100) }
          opts.on("-m", "--mute", "Start muted") { mute = true }
          opts.on("-f", "--fullscreen", "Start in fullscreen") { fullscreen = true }
          opts.on("--show-fps", "Show FPS counter") { show_fps = true }
          opts.on("--locale LANG", "Language (en, ja)") { |value| locale = value }
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.unknown_args { |before_dash, after_dash| positionals = before_dash + after_dash }
          opts.invalid_option do |flag|
            @io.puts "gemba play: unknown option #{flag}"
            help = true
          end
        end
        @parser = parser
        parser.parse(@argv.dup)

        Plan.new(
          rom: positionals.first?.try { |path| File.expand_path(path) },
          scale: scale, volume: volume, mute: mute, show_fps: show_fps,
          fullscreen: fullscreen, locale: locale, help: help)
      end

      @parser : OptionParser?
    end
  end
end
