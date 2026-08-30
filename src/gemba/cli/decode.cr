require "option_parser"
require "../recorder_decoder"
require "../paths"

module Gemba
  module CLI
    # `gemba decode` - encode a .grec to a playable video via ffmpeg,
    # `--stats` for a scan with no ffmpeg involved, `-l`/no-file for a
    # table of what the recordings directory holds. Args after `--`
    # replace the default codec flags wholesale, exactly as
    # RecorderDecoder's ffmpeg_args override.
    class Decode
      record Plan,
        grec : String? = nil, stats : Bool = false, list : Bool = false,
        output : String? = nil, video_codec : String? = nil, audio_codec : String? = nil,
        scale : Int32? = nil, ffmpeg_args : Array(String)? = nil,
        progress : Bool = true, help : Bool = false

      # recordings_dir feeds the listing; ffmpeg_bin is
      # RecorderDecoder's injectable executable seam - both spec
      # seams, both defaulted for real use.
      def initialize(@argv : Array(String), @dry_run : Bool = false, @io : IO = STDOUT,
                     @recordings_dir : String = Paths.recordings_dir,
                     @ffmpeg_bin : String = "ffmpeg")
      end

      def call : Plan
        plan = parse

        if plan.help
          @io.puts @parser unless @dry_run
          return plan
        end

        if plan.list || plan.grec.nil?
          list_recordings unless @dry_run
          return plan
        end
        return plan if @dry_run

        plan.stats ? show_stats(plan.grec.as(String)) : encode(plan)
        plan
      end

      private def parse : Plan
        output = nil.as(String?)
        video_codec = nil.as(String?)
        audio_codec = nil.as(String?)
        scale = nil.as(Int32?)
        list = false
        stats = false
        progress = true
        help = false
        positionals = [] of String
        passthrough = [] of String

        parser = OptionParser.new do |opts|
          opts.banner = <<-BANNER
            Usage: gemba decode [options] GREC_FILE [-- FFMPEG_ARGS...]

            Encode a .grec recording to a playable video via ffmpeg.
            Args after -- replace the default codec flags.
            BANNER
          opts.on("-o PATH", "--output PATH", "Output path (default: INPUT.mp4)") { |value| output = value }
          opts.on("--video-codec CODEC", "Video codec (default: libx264)") { |value| video_codec = value }
          opts.on("--audio-codec CODEC", "Audio codec (default: aac)") { |value| audio_codec = value }
          opts.on("-s N", "--scale N", "Scale factor (default: native)") { |value| scale = (value.to_i? || 1).clamp(1, 10) }
          opts.on("-l", "--list", "List available .grec recordings") { list = true }
          opts.on("--stats", "Show recording stats (no ffmpeg needed)") { stats = true }
          opts.on("--no-progress", "Disable progress indicator") { progress = false }
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.unknown_args do |before_dash, after_dash|
            positionals = before_dash
            passthrough = after_dash
          end
          opts.invalid_option do |flag|
            @io.puts "gemba decode: unknown option #{flag}"
            help = true
          end
        end
        @parser = parser
        parser.parse(@argv.dup)

        Plan.new(
          grec: positionals.first?,
          stats: stats, list: list, output: output,
          video_codec: video_codec, audio_codec: audio_codec, scale: scale,
          ffmpeg_args: passthrough.empty? ? nil : passthrough,
          progress: progress, help: help)
      end

      private def show_stats(grec : String) : Nil
        info = RecorderDecoder.stats(grec)
        @io.puts "Recording: #{grec}"
        @io.puts "  Frames:     #{info.frame_count}"
        @io.puts "  Resolution: #{info.width}x#{info.height}"
        @io.puts sprintf("  FPS:        %.2f", info.fps)
        @io.puts sprintf("  Duration:   %.1fs", info.duration)
        @io.puts sprintf("  Avg change: %.1f%%/frame", info.avg_change_pct)
        @io.puts "  Uncompressed: #{CLI.format_size(info.raw_video_size)} (encode input)"
        @io.puts "  Audio:      #{info.audio_rate} Hz, #{info.audio_channels}ch"
      end

      private def encode(plan : Plan) : Nil
        grec = plan.grec.as(String)
        output_path = plan.output || grec.sub(/\.grec\z/, "") + ".mp4"

        info = RecorderDecoder.decode(grec, output_path,
          video_codec: plan.video_codec || RecorderDecoder::DEFAULT_VIDEO_CODEC,
          audio_codec: plan.audio_codec || RecorderDecoder::DEFAULT_AUDIO_CODEC,
          scale: plan.scale, ffmpeg_args: plan.ffmpeg_args,
          progress: plan.progress, ffmpeg_bin: @ffmpeg_bin)

        @io.puts sprintf("Encoded %d frames (%dx%d @ %.2f fps, avg %.1f%% change/frame)",
          info.frame_count, info.width, info.height, info.fps, info.avg_change_pct)
        @io.puts "Output: #{output_path}"
      end

      # One aligned row per .grec in the recordings directory, ruby's
      # own default action when no file is named.
      private def list_recordings : Nil
        unless Dir.exists?(@recordings_dir)
          @io.puts "No recordings directory found at #{@recordings_dir}"
          return
        end

        paths = Dir.glob(File.join(@recordings_dir, "*.grec")).sort!
        if paths.empty?
          @io.puts "No .grec recordings in #{@recordings_dir}"
          return
        end

        rows = paths.map do |path|
          info = RecorderDecoder.stats(path)
          {path, "#{info.frame_count} frames", sprintf("%.1fs", info.duration),
           CLI.format_size(File.size(path))}
        end
        widths = {rows.max_of(&.[0].size), rows.max_of(&.[1].size),
                  rows.max_of(&.[2].size), rows.max_of(&.[3].size)}
        rows.each do |row|
          @io.puts "#{row[0].ljust(widths[0])}  #{row[1].rjust(widths[1])}  " \
                   "#{row[2].rjust(widths[2])}  #{row[3].rjust(widths[3])}"
        end
      end

      @parser : OptionParser?
    end
  end
end
