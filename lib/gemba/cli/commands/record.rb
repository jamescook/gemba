# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    module Commands
      class Record
        def initialize(argv, dry_run: false)
          @argv = argv
          @dry_run = dry_run
        end

        def call
          options = parse

          if options[:help]
            puts options[:parser] unless @dry_run
            return { command: :record, help: true }
          end

          unless options[:frames] && options[:rom]
            $stderr.puts "Error: record requires --frames N and a ROM file"
            $stderr.puts "Run 'gemba record --help' for usage"
            exit 1
          end

          result = {
            command: :record,
            rom: options[:rom],
            frames: options[:frames],
            output: options[:output],
            compression: options[:compression],
            progress: options[:progress],
            options: options.except(:parser)
          }
          return result if @dry_run

          require "gemba/headless"

          total = options[:frames]

          HeadlessPlayer.open(options[:rom]) do |player|
            rec_path = options[:output] ||
              "#{Config.rom_id(player.game_code, player.checksum)}.grec"

            rec_opts = {}
            rec_opts[:compression] = options[:compression] if options[:compression]
            player.start_recording(rec_path, **rec_opts)

            if options[:progress]
              last_print = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              player.step(total) do |frame|
                now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                if frame == total || now - last_print >= 0.5
                  pct = frame * 100.0 / total
                  $stderr.print "\rRecording: #{frame}/#{total} (#{'%.1f' % pct}%)\e[K"
                  last_print = now
                end
              end
              $stderr.print "\r\e[K"
            else
              player.step(total)
            end

            player.stop_recording

            info = RecorderDecoder.stats(rec_path)
            puts "Recorded #{info[:frame_count]} frames to #{rec_path}"
            puts "  Duration:   #{'%.1f' % info[:duration]}s"
            puts "  Avg change: #{'%.1f' % info[:avg_change_pct]}%/frame"
            puts "  Uncompressed: #{format_size(info[:raw_video_size])} (encode input)"
            puts "  .grec size: #{format_size(File.size(rec_path))}"
          end
        end

        def parse
          options = {}
          argv = @argv.dup

          parser = OptionParser.new do |o|
            o.banner = "Usage: gemba record [options] ROM_FILE"
            o.separator ""
            o.separator "Record video+audio to a .grec file (headless, no GUI)."
            o.separator ""

            o.on("--frames N", Integer, "Number of frames to record (required)") { |v| options[:frames] = v }
            o.on("-o", "--output PATH", "Output .grec path (default: ROM_ID.grec)") { |v| options[:output] = v }
            o.on("-c", "--compression N", Integer, "Zlib level 1-9 (default: 1)") { |v| options[:compression] = v.clamp(1, 9) }
            o.on("--progress", "Show recording progress") { options[:progress] = true }
            o.on("-h", "--help", "Show this help") { options[:help] = true }
          end

          parser.parse!(argv)
          options[:rom] = File.expand_path(argv.first) if argv.first
          options[:parser] = parser
          options
        end

        private

        def format_size(bytes)
          if bytes >= 1_073_741_824
            "#{'%.1f' % (bytes / 1_073_741_824.0)} GB"
          elsif bytes >= 1_048_576
            "#{'%.1f' % (bytes / 1_048_576.0)} MB"
          else
            "#{'%.1f' % (bytes / 1024.0)} KB"
          end
        end
      end
    end
  end
end
