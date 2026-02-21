# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    module Commands
      class Play
        def initialize(argv, dry_run: false)
          @argv = argv
          @dry_run = dry_run
        end

        def call
          options = parse

          if options[:help]
            puts options[:parser] unless @dry_run
            return { command: :play, help: true }
          end

          result = {
            command: :play,
            rom: options[:rom],
            sound: options.fetch(:sound, true),
            fullscreen: options[:fullscreen],
            options: options.except(:parser)
          }
          return result if @dry_run

          require "gemba"

          apply(Gemba.user_config, options)
          Gemba.load_locale if options[:locale]
          Gemba::AppController.new(result[:rom], sound: result[:sound], fullscreen: result[:fullscreen]).run
        end

        def parse
          options = {}
          argv = @argv.dup

          parser = OptionParser.new do |o|
            o.banner = "Usage: gemba [play] [options] [ROM_FILE]"
            o.separator ""
            o.separator "Launch the GBA emulator. ROM_FILE is optional."
            o.separator ""

            o.on("-s", "--scale N", Integer, "Window scale (1-4)") { |v| options[:scale] = v.clamp(1, 4) }
            o.on("-v", "--volume N", Integer, "Volume (0-100)") { |v| options[:volume] = v.clamp(0, 100) }
            o.on("-m", "--mute", "Start muted") { options[:mute] = true }
            o.on("--no-sound", "Disable audio entirely") { options[:sound] = false }
            o.on("-f", "--fullscreen", "Start in fullscreen") { options[:fullscreen] = true }
            o.on("--show-fps", "Show FPS counter") { options[:show_fps] = true }
            o.on("--turbo-speed N", Integer, "Fast-forward speed (0=uncapped, 2-4)") { |v| options[:turbo_speed] = v.clamp(0, 4) }
            o.on("--bios PATH", "Path to GBA BIOS file (overrides saved setting)") { |v| options[:bios] = File.expand_path(v) }
            o.on("--locale LANG", "Language (en, ja, auto)") { |v| options[:locale] = v }
            o.on("-h", "--help", "Show this help") { options[:help] = true }
          end

          parser.parse!(argv)
          options[:rom] = File.expand_path(argv.first) if argv.first
          options[:parser] = parser
          options
        end

        def apply(config, options)
          config.scale = options[:scale] if options[:scale]
          config.volume = options[:volume] if options[:volume]
          config.muted = true if options[:mute]
          config.show_fps = true if options[:show_fps]
          config.turbo_speed = options[:turbo_speed] if options[:turbo_speed]
          config.locale = options[:locale] if options[:locale]
          config.bios_path = options[:bios] if options[:bios]
        end
      end
    end
  end
end
