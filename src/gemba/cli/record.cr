require "option_parser"
require "../core"
require "../recorder"
require "../recorder_decoder"
require "../rom_library"

module Gemba
  module CLI
    # `gemba record --frames N rom.gba` - headless .grec capture:
    # drives a bare Core directly (no Tk, no SDL, no worker thread, no
    # pacing - as fast as the emulator runs) and feeds every frame to
    # Recorder, ruby's HeadlessPlayer-based record command flattened
    # into the loop it actually needs.
    class Record
      record Plan,
        rom : String?, frames : Int32?, output : String?,
        compression : Int32?, progress : Bool = false,
        help : Bool = false, error : String? = nil

      def initialize(@argv : Array(String), @dry_run : Bool = false,
                     @io : IO = STDOUT, @err : IO = STDERR)
      end

      def call : Plan
        plan = parse

        if plan.help
          @io.puts help_text unless @dry_run
          return plan
        end

        if error = plan.error
          raise Error.new("#{error}\nRun 'gemba record --help' for usage") unless @dry_run
          return plan
        end

        capture(plan) unless @dry_run
        plan
      end

      private def parse : Plan
        frames = nil.as(Int32?)
        output = nil.as(String?)
        compression = nil.as(Int32?)
        progress = false
        help = false
        positionals = [] of String

        parser = build_parser do |opts|
          opts.on("--frames N", "Number of frames to record (required)") { |value| frames = value.to_i? }
          opts.on("-o PATH", "--output PATH", "Output .grec path (default: ROM_ID.grec)") { |value| output = value }
          opts.on("-c N", "--compression N", "Zlib level 1-9 (default: 1)") { |value| compression = (value.to_i? || 1).clamp(1, 9) }
          opts.on("--progress", "Show recording progress") { progress = true }
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.unknown_args { |before_dash, after_dash| positionals = before_dash + after_dash }
          opts.invalid_option do |flag|
            @io.puts "gemba record: unknown option #{flag}"
            help = true
          end
        end
        @parser = parser
        parser.parse(@argv.dup)

        rom = positionals.first?.try { |path| File.expand_path(path) }
        error = frames && rom ? nil : "record requires --frames N and a ROM file"
        Plan.new(rom: rom, frames: frames, output: output, compression: compression,
          progress: progress, help: help, error: help ? nil : error)
      end

      private def capture(plan : Plan) : Nil
        core = Core.new(plan.rom.as(String))
        begin
          path = plan.output || "#{RomLibrary.rom_id(core.game_code, core.checksum)}.grec"
          recorder = Recorder.new(path, core.width, core.height,
            compression: plan.compression || 1)
          recorder.start
          run_frames(core, recorder, plan.frames.as(Int32), plan.progress)
          recorder.stop
          report(path)
        ensure
          core.destroy
        end
      end

      private def run_frames(core : Core, recorder : Recorder, total : Int32, progress : Bool) : Nil
        last_print = Time.instant - 1.seconds
        total.times do |i|
          core.run_frame
          recorder.capture(core.video_buffer, core.audio_buffer)
          next unless progress

          frame = i + 1
          now = Time.instant
          if frame == total || now - last_print >= 0.5.seconds
            @err.print sprintf("\rRecording: %d/%d (%.1f%%)\e[K", frame, total, frame * 100.0 / total)
            last_print = now
          end
        end
        @err.print "\r\e[K" if progress
      end

      private def report(path : String) : Nil
        info = RecorderDecoder.stats(path)
        @io.puts "Recorded #{info.frame_count} frames to #{path}"
        @io.puts sprintf("  Duration:   %.1fs", info.duration)
        @io.puts sprintf("  Avg change: %.1f%%/frame", info.avg_change_pct)
        @io.puts "  Uncompressed: #{CLI.format_size(info.raw_video_size)} (encode input)"
        @io.puts "  .grec size: #{CLI.format_size(File.size(path))}"
      end

      private def build_parser(& : OptionParser -> Nil) : OptionParser
        OptionParser.new do |opts|
          opts.banner = <<-BANNER
            Usage: gemba record [options] ROM_FILE

            Record video+audio to a .grec file (headless, no GUI).
            BANNER
          yield opts
        end
      end

      # Always set by the time a help path prints it - #parse runs
      # first in #call.
      private def help_text : String
        @parser.to_s
      end

      @parser : OptionParser?
    end
  end
end
