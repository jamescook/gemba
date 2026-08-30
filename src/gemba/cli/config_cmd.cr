require "option_parser"
require "../config"

module Gemba
  module CLI
    # `gemba config` - show where the settings file lives and its main
    # knobs; `--reset` deletes it (saves/states untouched), with a
    # confirmation prompt unless -y. Mirrors ruby's config_cmd.rb minus
    # the turbo-speed line (no such knob in this port's Config yet).
    class ConfigCmd
      record Plan, action : Symbol, yes : Bool = false, help : Bool = false

      def initialize(@argv : Array(String), @dry_run : Bool = false,
                     @io : IO = STDOUT, @input : IO = STDIN,
                     @config_path : String = Config.path)
      end

      def call : Plan
        reset = false
        yes = false
        help = false

        parser = OptionParser.new do |opts|
          opts.banner = <<-BANNER
            Usage: gemba config [options]

            Show or reset configuration.
            BANNER
          opts.on("--reset", "Delete the settings file (keeps saves)") { reset = true }
          opts.on("-y", "--yes", "Skip confirmation prompts") { yes = true }
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.invalid_option do |flag|
            @io.puts "gemba config: unknown option #{flag}"
            help = true
          end
        end
        parser.parse(@argv.dup)

        if help
          @io.puts parser unless @dry_run
          return Plan.new(action: :help, help: true)
        end

        plan = Plan.new(action: reset ? :reset : :show, yes: yes)
        return plan if @dry_run

        reset ? do_reset(yes) : show
        plan
      end

      private def show : Nil
        exists = File.exists?(@config_path)
        @io.puts "Config: #{@config_path}"
        @io.puts "  Exists: #{exists}"
        return unless exists

        config = Config.new(@config_path)
        @io.puts "  Scale: #{config.scale}"
        @io.puts "  Volume: #{config.volume}"
        @io.puts "  Muted: #{config.muted?}"
        @io.puts "  Locale: #{config.locale}"
        @io.puts "  Show FPS: #{config.show_fps?}"
      end

      private def do_reset(yes : Bool) : Nil
        unless File.exists?(@config_path)
          @io.puts "No config file found at #{@config_path}"
          return
        end

        unless yes
          @io.print "Delete #{@config_path}? [y/N] "
          answer = @input.gets.try(&.strip.downcase)
          return unless answer == "y"
        end

        File.delete(@config_path)
        @io.puts "Deleted #{@config_path}"
      end
    end
  end
end
