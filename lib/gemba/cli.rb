# frozen_string_literal: true

require 'optparse'
require_relative 'version'

module Gemba
  class CLI
    SUBCOMMANDS = %w[record decode info replay].freeze

    # Entry point: dispatch to subcommand or player.
    # @param argv [Array<String>]
    def self.run(argv = ARGV)
      args = argv.dup

      case args.first
      when 'record'
        args.shift
        run_record(args)
      when 'decode'
        args.shift
        run_decode(args)
      when 'info'
        args.shift
        run_info(args)
      when 'replay'
        args.shift
        run_replay(args)
      else
        run_player(args)
      end
    end

    # Parse player (default) command options.
    # @param argv [Array<String>]
    # @return [Hash]
    def self.parse(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba [options] [ROM_FILE]"
        o.separator ""
        o.separator "GBA emulator powered by teek + libmgba"
        o.separator ""
        o.separator "Commands:"
        o.separator "  record    Record video+audio to .grec (headless)"
        o.separator "  decode    Encode .grec to video via ffmpeg"
        o.separator "  info      Show .grec recording stats"
        o.separator "  replay    Replay a .gir input recording (headless)"
        o.separator ""
        o.separator "Player options:"

        o.on("-s", "--scale N", Integer, "Window scale (1-4)") do |v|
          options[:scale] = v.clamp(1, 4)
        end

        o.on("-v", "--volume N", Integer, "Volume (0-100)") do |v|
          options[:volume] = v.clamp(0, 100)
        end

        o.on("-m", "--mute", "Start muted") do
          options[:mute] = true
        end

        o.on("--no-sound", "Disable audio entirely") do
          options[:sound] = false
        end

        o.on("-f", "--fullscreen", "Start in fullscreen") do
          options[:fullscreen] = true
        end

        o.on("--show-fps", "Show FPS counter") do
          options[:show_fps] = true
        end

        o.on("--turbo-speed N", Integer, "Fast-forward speed (0=uncapped, 2-4)") do |v|
          options[:turbo_speed] = v.clamp(0, 4)
        end

        o.on("--locale LANG", "Language (en, ja, auto)") do |v|
          options[:locale] = v
        end

        o.on("--headless", "Run without GUI (requires --frames and ROM)") do
          options[:headless] = true
        end

        o.on("--frames N", Integer, "Run N frames then exit (requires ROM)") do |v|
          options[:frames] = v
        end

        o.on("--reset-config", "Delete settings file and exit (keeps saves)") do
          options[:reset_config] = true
        end

        o.on("-y", "--yes", "Skip confirmation prompts") do
          options[:yes] = true
        end

        o.on("--version", "Show version") do
          options[:version] = true
        end

        o.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
      end

      parser.parse!(argv)
      options[:rom] = File.expand_path(argv.first) if argv.first
      options[:parser] = parser
      options
    end

    # Apply parsed CLI options to the user config (session-only overrides).
    # @param config [Gemba::Config]
    # @param options [Hash]
    def self.apply(config, options)
      config.scale = options[:scale] if options[:scale]
      config.volume = options[:volume] if options[:volume]
      config.muted = true if options[:mute]
      config.show_fps = true if options[:show_fps]
      config.turbo_speed = options[:turbo_speed] if options[:turbo_speed]
      config.locale = options[:locale] if options[:locale]
    end

    # --- Player (default command) ---

    def self.run_player(argv)
      options = parse(argv)

      if options[:help]
        puts options[:parser]
        return
      end

      if options[:version]
        puts "gemba #{Gemba::VERSION}"
        return
      end

      require "gemba"

      if options[:reset_config]
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

      if options[:headless]
        unless options[:frames] && options[:rom]
          $stderr.puts "Error: --headless requires --frames N and a ROM file"
          exit 1
        end
        require "gemba/headless"
        HeadlessPlayer.open(options[:rom]) { |p| p.step(options[:frames]) }
        return
      end

      if options[:frames] && !options[:rom]
        $stderr.puts "Error: --frames requires a ROM file"
        exit 1
      end

      apply(Gemba.user_config, options)
      Gemba.load_locale if options[:locale]

      sound = options.fetch(:sound, true)
      Player.new(options[:rom], sound: sound, fullscreen: options[:fullscreen],
                 frames: options[:frames]).run
    end
    private_class_method :run_player

    # --- record subcommand ---

    def self.parse_record(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba record [options] ROM_FILE"
        o.separator ""
        o.separator "Record video+audio to a .grec file (headless, no GUI)"
        o.separator ""

        o.on("--frames N", Integer, "Number of frames to record (required)") do |v|
          options[:frames] = v
        end

        o.on("-o", "--output PATH", "Output .grec path (default: ROM_ID.grec)") do |v|
          options[:output] = v
        end

        o.on("-c", "--compression N", Integer, "Zlib level 1-9 (default: 1, 6+ has diminishing returns)") do |v|
          options[:compression] = v.clamp(1, 9)
        end

        o.on("--progress", "Show recording progress") do
          options[:progress] = true
        end

        o.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
      end

      parser.parse!(argv)
      options[:rom] = File.expand_path(argv.first) if argv.first
      options[:parser] = parser
      options
    end

    def self.run_record(argv)
      options = parse_record(argv)

      if options[:help]
        puts options[:parser]
        return
      end

      unless options[:frames] && options[:rom]
        $stderr.puts "Error: record requires --frames N and a ROM file"
        $stderr.puts "Run 'gemba record --help' for usage"
        exit 1
      end

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
    private_class_method :run_record

    # --- decode subcommand ---

    def self.parse_decode(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba decode [options] TREC_FILE [-- FFMPEG_ARGS...]"
        o.separator ""
        o.separator "Encode a .grec recording to a playable video via ffmpeg."
        o.separator "Args after -- replace the default codec flags (-c:v, -c:a, etc)."
        o.separator ""

        o.on("-o", "--output PATH", "Output path (default: INPUT.mp4)") do |v|
          options[:output] = v
        end

        o.on("--video-codec CODEC", "Video codec (default: libx264)") do |v|
          options[:video_codec] = v
        end

        o.on("--audio-codec CODEC", "Audio codec (default: aac)") do |v|
          options[:audio_codec] = v
        end

        o.on("-s", "--scale N", Integer, "Scale factor (default: native)") do |v|
          options[:scale] = v.clamp(1, 10)
        end

        o.on("--no-progress", "Disable progress indicator") do
          options[:progress] = false
        end

        o.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
      end

      parser.parse!(argv)
      options[:trec] = argv.shift
      options[:ffmpeg_args] = argv unless argv.empty?
      options[:parser] = parser
      options
    end

    def self.run_decode(argv)
      options = parse_decode(argv)

      if options[:help]
        puts options[:parser]
        return
      end

      unless options[:trec]
        $stderr.puts "Error: decode requires a .grec file"
        $stderr.puts "Run 'gemba decode --help' for usage"
        exit 1
      end

      require "gemba/headless"

      trec_path = options[:trec]
      output_path = options[:output] || trec_path.sub(/\.grec\z/, '') + '.mp4'
      codec_opts = {}
      codec_opts[:video_codec] = options[:video_codec] if options[:video_codec]
      codec_opts[:audio_codec] = options[:audio_codec] if options[:audio_codec]
      codec_opts[:scale] = options[:scale] if options[:scale]
      codec_opts[:ffmpeg_args] = options[:ffmpeg_args] if options[:ffmpeg_args]
      codec_opts[:progress] = options.fetch(:progress, true)

      info = RecorderDecoder.decode(trec_path, output_path, **codec_opts)
      puts "Encoded #{info[:frame_count]} frames " \
           "(#{info[:width]}x#{info[:height]} @ #{'%.2f' % info[:fps]} fps, " \
           "avg #{'%.1f' % info[:avg_change_pct]}% change/frame)"
      puts "Output: #{info[:output_path]}"
    end
    private_class_method :run_decode

    # --- info subcommand ---

    def self.run_info(argv)
      if argv.include?('--help') || argv.include?('-h') || argv.empty?
        puts "Usage: gemba info TREC_FILE"
        puts ""
        puts "Show recording stats (no ffmpeg needed)"
        return
      end

      require "gemba/headless"

      trec_path = argv.first
      info = RecorderDecoder.stats(trec_path)

      puts "Recording: #{trec_path}"
      puts "  Frames:     #{info[:frame_count]}"
      puts "  Resolution: #{info[:width]}x#{info[:height]}"
      puts "  FPS:        #{'%.2f' % info[:fps]}"
      puts "  Duration:   #{'%.1f' % info[:duration]}s"
      puts "  Avg change: #{'%.1f' % info[:avg_change_pct]}%/frame"
      puts "  Uncompressed: #{format_size(info[:raw_video_size])} (encode input)"
      puts "  Audio:      #{info[:audio_rate]} Hz, #{info[:audio_channels]}ch"
    end
    private_class_method :run_info

    # --- replay subcommand ---

    def self.parse_replay(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba replay [options] GIR_FILE [ROM_FILE]"
        o.separator ""
        o.separator "Replay a .gir input recording."
        o.separator "ROM is read from the .gir header; override with ROM_FILE."
        o.separator ""

        o.on("-l", "--list", "List available .gir recordings") do
          options[:list] = true
        end

        o.on("--headless", "Run without GUI (print summary and exit)") do
          options[:headless] = true
        end

        o.on("--progress", "Show progress (headless only)") do
          options[:progress] = true
        end

        o.on("-f", "--fullscreen", "Start in fullscreen") do
          options[:fullscreen] = true
        end

        o.on("--no-sound", "Disable audio") do
          options[:sound] = false
        end

        o.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
      end

      parser.parse!(argv)
      options[:gir] = argv.shift
      options[:rom] = argv.shift
      options[:parser] = parser
      options
    end

    def self.run_replay(argv)
      options = parse_replay(argv)

      if options[:help]
        puts options[:parser]
        return
      end

      if options[:list]
        list_recordings
        return
      end

      unless options[:gir]
        $stderr.puts "Error: replay requires a .gir file"
        $stderr.puts "Run 'gemba replay --help' for usage"
        exit 1
      end

      gir_path = File.expand_path(options[:gir])

      if options[:headless]
        run_replay_headless(gir_path, options)
      else
        run_replay_gui(gir_path, options)
      end
    end

    def self.run_replay_headless(gir_path, options)
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

    def self.run_replay_gui(gir_path, options)
      require "gemba"

      sound = options.fetch(:sound, true)
      ReplayPlayer.new(gir_path,
                       sound: sound,
                       fullscreen: options[:fullscreen]).run
    end

    def self.list_recordings
      require_relative "config"
      require_relative "input_replayer"

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
    private_class_method :run_replay

    def self.format_size(bytes)
      if bytes >= 1_073_741_824
        "#{'%.1f' % (bytes / 1_073_741_824.0)} GB"
      elsif bytes >= 1_048_576
        "#{'%.1f' % (bytes / 1_048_576.0)} MB"
      else
        "#{'%.1f' % (bytes / 1024.0)} KB"
      end
    end
    private_class_method :format_size
  end
end
