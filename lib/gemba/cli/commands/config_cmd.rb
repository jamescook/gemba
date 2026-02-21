# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    module Commands
      class ConfigCmd
        def initialize(argv, dry_run: false)
          @argv = argv
          @dry_run = dry_run
        end

        def call
          options = parse

          if options[:help]
            puts options[:parser] unless @dry_run
            return { command: :config, help: true }
          end

          result = {
            command: options[:reset] ? :config_reset : :config_show,
            reset: options[:reset],
            yes: options[:yes],
            options: options.except(:parser)
          }
          return result if @dry_run

          require "gemba"

          if options[:reset]
            path = Config.default_path
            unless File.exist?(path)
              puts "No config file found at #{path}"
              return
            end
            unless options[:yes]
              print "Delete #{path}? [y/N] "
              return unless $stdin.gets&.strip&.downcase == 'y'
            end
            Config.reset!(path: path)
            puts "Deleted #{path}"
            return
          end

          path = Config.default_path
          puts "Config: #{path}"
          puts "  Exists: #{File.exist?(path)}"
          if File.exist?(path)
            config = Gemba.user_config
            puts "  Scale: #{config.scale}"
            puts "  Volume: #{config.volume}"
            puts "  Muted: #{config.muted?}"
            puts "  Locale: #{config.locale}"
            puts "  Show FPS: #{config.show_fps?}"
            puts "  Turbo speed: #{config.turbo_speed}"
          end
        end

        def parse
          options = {}
          argv = @argv.dup

          parser = OptionParser.new do |o|
            o.banner = "Usage: gemba config [options]"
            o.separator ""
            o.separator "Show or reset configuration."
            o.separator ""

            o.on("--reset", "Delete settings file (keeps saves)") { options[:reset] = true }
            o.on("-y", "--yes", "Skip confirmation prompts") { options[:yes] = true }
            o.on("-h", "--help", "Show this help") { options[:help] = true }
          end

          parser.parse!(argv)
          options[:parser] = parser
          options
        end
      end
    end
  end
end
