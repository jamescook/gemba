# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    module Commands
      class Replay
        def initialize(argv, dry_run: false)
          @argv = argv
          @dry_run = dry_run
        end

        def call
          options = parse

          if options[:help]
            puts options[:parser] unless @dry_run
            return { command: :replay, help: true }
          end

          if options[:list]
            list_recordings unless @dry_run
            return { command: :replay_list }
          end

          unless options[:gir]
            $stderr.puts "Error: replay requires a .gir file"
            $stderr.puts "Run 'gemba replay --help' for usage"
            exit 1
          end

          gir_path = File.expand_path(options[:gir])

          result = {
            command: options[:headless] ? :replay_headless : :replay,
            gir: gir_path,
            rom: options[:rom],
            sound: options.fetch(:sound, true),
            fullscreen: options[:fullscreen],
            headless: options[:headless],
            progress: options[:progress],
            options: options.except(:parser)
          }
          return result if @dry_run

          if options[:headless]
            run_headless(gir_path, options)
          else
            run_gui(gir_path, options)
          end
        end

        def parse
          options = {}
          argv = @argv.dup

          parser = OptionParser.new do |o|
            o.banner = "Usage: gemba replay [options] GIR_FILE [ROM_FILE]"
            o.separator ""
            o.separator "Replay a .gir input recording."
            o.separator "ROM is read from the .gir header; override with ROM_FILE."
            o.separator ""

            o.on("-l", "--list", "List available .gir recordings") { options[:list] = true }
            o.on("--headless", "Run without GUI (print summary and exit)") { options[:headless] = true }
            o.on("--progress", "Show progress (headless only)") { options[:progress] = true }
            o.on("-f", "--fullscreen", "Start in fullscreen") { options[:fullscreen] = true }
            o.on("--no-sound", "Disable audio") { options[:sound] = false }
            o.on("-h", "--help", "Show this help") { options[:help] = true }
          end

          parser.parse!(argv)
          options[:gir] = argv.shift
          options[:rom] = argv.shift
          options[:parser] = parser
          options
        end

        private

        def run_headless(gir_path, options)
          require "gemba/headless"

          rom_path = options[:rom]
          unless rom_path
            replayer = Gemba::InputReplayer.new(gir_path)
            rom_path = replayer.rom_path
            unless rom_path
              $stderr.puts "Error: .gir has no rom_path in header; pass ROM_FILE explicitly"
              exit 1
            end
          end
          rom_path = File.expand_path(rom_path)

          Gemba::HeadlessPlayer.open(rom_path) do |player|
            if options[:progress]
              replayer = Gemba::InputReplayer.new(gir_path)
              total = replayer.frame_count
              last_print = Process.clock_gettime(Process::CLOCK_MONOTONIC)

              player.replay(gir_path) do |_mask, idx|
                now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                frame = idx + 1
                if frame == total || now - last_print >= 0.5
                  pct = frame * 100.0 / total
                  $stderr.print "\rReplaying: #{frame}/#{total} (#{'%.1f' % pct}%)\e[K"
                  last_print = now
                end
              end
              $stderr.print "\r\e[K"
            else
              player.replay(gir_path)
            end

            puts "Replayed #{gir_path} (#{Gemba::InputReplayer.new(gir_path).frame_count} frames)"
          end
        end

        def run_gui(gir_path, options)
          require "gemba"

          sound = options.fetch(:sound, true)
          ReplayPlayer.new(gir_path,
                           sound: sound,
                           fullscreen: options[:fullscreen]).run
        end

        def list_recordings
          require "gemba/headless"

          dir = Config.default_recordings_dir
          unless File.directory?(dir)
            puts "No recordings directory found at #{dir}"
            return
          end

          gir_files = Dir.glob(File.join(dir, '*.gir')).sort
          if gir_files.empty?
            puts "No .gir recordings in #{dir}"
            return
          end

          by_rom = {}
          gir_files.each do |path|
            replayer = InputReplayer.new(path)
            key = replayer.game_code || "unknown"
            (by_rom[key] ||= []) << { path: path, frames: replayer.frame_count }
          end

          by_rom.each do |game_code, entries|
            puts "#{game_code}:"
            entries.each do |entry|
              puts "  #{entry[:path]}  (#{entry[:frames]} frames)"
            end
          end
        end
      end
    end
  end
end
