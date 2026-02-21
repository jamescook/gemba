# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    module Commands
      class Decode
        def initialize(argv, dry_run: false)
          @argv = argv
          @dry_run = dry_run
        end

        def call
          options = parse

          if options[:help]
            puts options[:parser] unless @dry_run
            return { command: :decode, help: true }
          end

          if options[:list]
            list_grec_recordings unless @dry_run
            return { command: :decode_list }
          end

          unless options[:grec]
            list_grec_recordings unless @dry_run
            return { command: :decode_list }
          end

          result = {
            command: options[:stats] ? :decode_stats : :decode,
            grec: options[:grec],
            stats: options[:stats],
            output: options[:output],
            video_codec: options[:video_codec],
            audio_codec: options[:audio_codec],
            scale: options[:scale],
            ffmpeg_args: options[:ffmpeg_args],
            options: options.except(:parser)
          }
          return result if @dry_run

          require "gemba/headless"

          grec_path = options[:grec]

          if options[:stats]
            info = RecorderDecoder.stats(grec_path)
            puts "Recording: #{grec_path}"
            puts "  Frames:     #{info[:frame_count]}"
            puts "  Resolution: #{info[:width]}x#{info[:height]}"
            puts "  FPS:        #{'%.2f' % info[:fps]}"
            puts "  Duration:   #{'%.1f' % info[:duration]}s"
            puts "  Avg change: #{'%.1f' % info[:avg_change_pct]}%/frame"
            puts "  Uncompressed: #{format_size(info[:raw_video_size])} (encode input)"
            puts "  Audio:      #{info[:audio_rate]} Hz, #{info[:audio_channels]}ch"
            return
          end

          output_path = options[:output] || grec_path.sub(/\.grec\z/, '') + '.mp4'
          codec_opts = {}
          codec_opts[:video_codec] = options[:video_codec] if options[:video_codec]
          codec_opts[:audio_codec] = options[:audio_codec] if options[:audio_codec]
          codec_opts[:scale] = options[:scale] if options[:scale]
          codec_opts[:ffmpeg_args] = options[:ffmpeg_args] if options[:ffmpeg_args]
          codec_opts[:progress] = options.fetch(:progress, true)

          info = RecorderDecoder.decode(grec_path, output_path, **codec_opts)
          puts "Encoded #{info[:frame_count]} frames " \
               "(#{info[:width]}x#{info[:height]} @ #{'%.2f' % info[:fps]} fps, " \
               "avg #{'%.1f' % info[:avg_change_pct]}% change/frame)"
          puts "Output: #{info[:output_path]}"
        end

        def parse
          options = {}
          argv = @argv.dup

          parser = OptionParser.new do |o|
            o.banner = "Usage: gemba decode [options] GREC_FILE [-- FFMPEG_ARGS...]"
            o.separator ""
            o.separator "Encode a .grec recording to a playable video via ffmpeg."
            o.separator "Args after -- replace the default codec flags."
            o.separator ""

            o.on("-o", "--output PATH", "Output path (default: INPUT.mp4)") { |v| options[:output] = v }
            o.on("--video-codec CODEC", "Video codec (default: libx264)") { |v| options[:video_codec] = v }
            o.on("--audio-codec CODEC", "Audio codec (default: aac)") { |v| options[:audio_codec] = v }
            o.on("-s", "--scale N", Integer, "Scale factor (default: native)") { |v| options[:scale] = v.clamp(1, 10) }
            o.on("-l", "--list", "List available .grec recordings") { options[:list] = true }
            o.on("--stats", "Show recording stats (no ffmpeg needed)") { options[:stats] = true }
            o.on("--no-progress", "Disable progress indicator") { options[:progress] = false }
            o.on("-h", "--help", "Show this help") { options[:help] = true }
          end

          parser.parse!(argv)
          options[:grec] = argv.shift
          options[:ffmpeg_args] = argv unless argv.empty?
          options[:parser] = parser
          options
        end

        private

        def list_grec_recordings
          require "gemba/headless"

          dir = Config.default_recordings_dir
          unless File.directory?(dir)
            puts "No recordings directory found at #{dir}"
            return
          end

          grec_files = Dir.glob(File.join(dir, '*.grec')).sort
          if grec_files.empty?
            puts "No .grec recordings in #{dir}"
            return
          end

          entries = grec_files.map do |path|
            info = RecorderDecoder.stats(path)
            {
              path: path,
              frames: "#{info[:frame_count]} frames",
              duration: "#{'%.1f' % info[:duration]}s",
              size: format_size(File.size(path))
            }
          end

          path_w   = entries.map { |e| e[:path].length }.max
          frames_w = entries.map { |e| e[:frames].length }.max
          dur_w    = entries.map { |e| e[:duration].length }.max
          size_w   = entries.map { |e| e[:size].length }.max

          entries.each do |e|
            puts "#{e[:path].ljust(path_w)}  #{e[:frames].rjust(frames_w)}  #{e[:duration].rjust(dur_w)}  #{e[:size].rjust(size_w)}"
          end
        end

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
