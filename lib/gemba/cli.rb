# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    SUBCOMMANDS = %w[play record decode replay config version].freeze

    # Entry point: dispatch to subcommand or default to play.
    # @param argv [Array<String>]
    # @param dry_run [Boolean] parse and validate only, return execution plan
    def self.run(argv = ARGV, dry_run: false)
      args = argv.dup

      if args.first == '--help' || args.first == '-h'
        puts main_help unless dry_run
        return { command: :help }
      end

      cmd = SUBCOMMANDS.include?(args.first) ? args.shift : 'play'
      send(:"run_#{cmd}", args, dry_run: dry_run)
    end

    # Main help text listing all subcommands.
    def self.main_help
      <<~HELP
        Usage: gemba [command] [options]

        GBA emulator powered by teek + libmgba

        Commands:
          play      Play a ROM (default)
          record    Record video+audio to .grec (headless)
          decode    Encode .grec to video via ffmpeg (--stats for info)
          replay    Replay a .gir input recording
          config    Show or reset configuration
          version   Show version

        Run 'gemba <command> --help' for command-specific options.
      HELP
    end

    # --- play (default command) ---

    def self.parse_play(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba [play] [options] [ROM_FILE]"
        o.separator ""
        o.separator "Launch the GBA emulator. ROM_FILE is optional."
        o.separator ""

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

    def self.run_play(argv, dry_run: false)
      options = parse_play(argv)

      if options[:help]
        puts options[:parser] unless dry_run
        return { command: :play, help: true }
      end

      result = {
        command: :play,
        rom: options[:rom],
        sound: options.fetch(:sound, true),
        fullscreen: options[:fullscreen],
        options: options.except(:parser)
      }
      return result if dry_run

      require "gemba"

      apply(Gemba.user_config, options)
      Gemba.load_locale if options[:locale]

      Gemba::AppController.new(result[:rom], sound: result[:sound], fullscreen: result[:fullscreen]).run
    end

    # --- record subcommand ---

    def self.parse_record(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba record [options] ROM_FILE"
        o.separator ""
        o.separator "Record video+audio to a .grec file (headless, no GUI)."
        o.separator ""

        o.on("--frames N", Integer, "Number of frames to record (required)") do |v|
          options[:frames] = v
        end

        o.on("-o", "--output PATH", "Output .grec path (default: ROM_ID.grec)") do |v|
          options[:output] = v
        end

        o.on("-c", "--compression N", Integer, "Zlib level 1-9 (default: 1)") do |v|
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

    def self.run_record(argv, dry_run: false)
      options = parse_record(argv)

      if options[:help]
        puts options[:parser] unless dry_run
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
      return result if dry_run

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

    # --- decode subcommand ---

    def self.parse_decode(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba decode [options] GREC_FILE [-- FFMPEG_ARGS...]"
        o.separator ""
        o.separator "Encode a .grec recording to a playable video via ffmpeg."
        o.separator "Args after -- replace the default codec flags."
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

        o.on("-l", "--list", "List available .grec recordings") do
          options[:list] = true
        end

        o.on("--stats", "Show recording stats (no ffmpeg needed)") do
          options[:stats] = true
        end

        o.on("--no-progress", "Disable progress indicator") do
          options[:progress] = false
        end

        o.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
      end

      parser.parse!(argv)
      options[:grec] = argv.shift
      options[:ffmpeg_args] = argv unless argv.empty?
      options[:parser] = parser
      options
    end

    def self.run_decode(argv, dry_run: false)
      options = parse_decode(argv)

      if options[:help]
        puts options[:parser] unless dry_run
        return { command: :decode, help: true }
      end

      if options[:list]
        list_grec_recordings unless dry_run
        return { command: :decode_list }
      end

      unless options[:grec]
        list_grec_recordings unless dry_run
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
      return result if dry_run

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

    def self.run_replay(argv, dry_run: false)
      options = parse_replay(argv)

      if options[:help]
        puts options[:parser] unless dry_run
        return { command: :replay, help: true }
      end

      if options[:list]
        list_recordings unless dry_run
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
      return result if dry_run

      if options[:headless]
        run_replay_headless(gir_path, options)
      else
        run_replay_gui(gir_path, options)
      end
    end

    # --- config subcommand ---

    def self.parse_config(argv)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: gemba config [options]"
        o.separator ""
        o.separator "Show or reset configuration."
        o.separator ""

        o.on("--reset", "Delete settings file (keeps saves)") do
          options[:reset] = true
        end

        o.on("-y", "--yes", "Skip confirmation prompts") do
          options[:yes] = true
        end

        o.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
      end

      parser.parse!(argv)
      options[:parser] = parser
      options
    end

    def self.run_config(argv, dry_run: false)
      options = parse_config(argv)

      if options[:help]
        puts options[:parser] unless dry_run
        return { command: :config, help: true }
      end

      result = {
        command: options[:reset] ? :config_reset : :config_show,
        reset: options[:reset],
        yes: options[:yes],
        options: options.except(:parser)
      }
      return result if dry_run

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

      # Default: show config info
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

    # --- version subcommand ---

    def self.run_version(_argv, dry_run: false)
      result = { command: :version, version: Gemba::VERSION }
      return result if dry_run

      puts "gemba #{Gemba::VERSION}"
    end

    # --- helpers ---

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
    private_class_method :run_replay_headless

    def self.run_replay_gui(gir_path, options)
      require "gemba"

      sound = options.fetch(:sound, true)
      ReplayPlayer.new(gir_path,
                       sound: sound,
                       fullscreen: options[:fullscreen]).run
    end
    private_class_method :run_replay_gui

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
    private_class_method :list_recordings

    def self.list_grec_recordings
      require_relative "config"
      require_relative "recorder"
      require_relative "recorder_decoder"

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

      path_w = entries.map { |e| e[:path].length }.max
      frames_w = entries.map { |e| e[:frames].length }.max
      dur_w = entries.map { |e| e[:duration].length }.max
      size_w = entries.map { |e| e[:size].length }.max

      entries.each do |e|
        puts "#{e[:path].ljust(path_w)}  #{e[:frames].rjust(frames_w)}  #{e[:duration].rjust(dur_w)}  #{e[:size].rjust(size_w)}"
      end
    end
    private_class_method :list_grec_recordings

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
