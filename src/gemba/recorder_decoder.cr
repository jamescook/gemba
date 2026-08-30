require "compress/zlib"
require "./frame_delta"
require "./recorder"

module Gemba
  # Decodes a .grec file (see Recorder) and encodes it to a playable
  # video via ffmpeg - the ruby RecorderDecoder port, same two-pass
  # shape so RAM stays flat no matter how long the recording is:
  #
  #   Pass 1: read the header, count frames, sum change percentages,
  #           and extract the raw PCM to a small tempfile - video
  #           chunks are seeked over, not read.
  #   Pass 2: inflate + un-XOR video frames one at a time, piping each
  #           straight to ffmpeg's stdin while ffmpeg reads the audio
  #           from the tempfile.
  #
  # .stats does pass 1 alone (no ffmpeg needed) - what a CLI `gemba
  # decode --stats` or a picker tooltip wants.
  class RecorderDecoder
    class FormatError < Exception; end

    class FfmpegNotFound < Exception; end

    DEFAULT_VIDEO_CODEC = "libx264"
    DEFAULT_AUDIO_CODEC = "aac"
    HEADER_SIZE         = 32

    # Everything a scan learns about a recording. duration/raw_video_size
    # are derived (frame count against the header's fps/dimensions).
    record Stats,
      frame_count : Int32, width : Int32, height : Int32,
      fps : Float64, duration : Float64, avg_change_pct : Float64,
      raw_video_size : Int64, audio_rate : Int32, audio_channels : Int32

    private record Header,
      width : Int32, height : Int32,
      fps_num : UInt32, fps_den : UInt32,
      audio_rate : Int32, audio_channels : Int32, audio_bits : Int32

    def self.stats(grec_path : String) : Stats
      new(grec_path, "").stats
    end

    # Decode grec_path into output_path (extension picks the container:
    # .mp4, .mkv...). scale upscales with nearest-neighbor (pixel-art
    # crisp); ffmpeg_args replaces the codec arguments wholesale for
    # callers that know exactly what they want. progress prints an
    # updating "Encoding: N/M" line to STDERR, ruby-style.
    def self.decode(grec_path : String, output_path : String,
                    video_codec : String = DEFAULT_VIDEO_CODEC,
                    audio_codec : String = DEFAULT_AUDIO_CODEC,
                    scale : Int32? = nil, ffmpeg_args : Array(String)? = nil,
                    progress : Bool = true) : Stats
      new(grec_path, output_path, video_codec: video_codec, audio_codec: audio_codec,
        scale: scale, ffmpeg_args: ffmpeg_args, progress: progress).decode
    end

    def initialize(@grec_path : String, @output_path : String,
                   @video_codec : String = DEFAULT_VIDEO_CODEC,
                   @audio_codec : String = DEFAULT_AUDIO_CODEC,
                   @scale : Int32? = nil, @ffmpeg_args : Array(String)? = nil,
                   @progress : Bool = true)
    end

    # Pass 1 alone: header plus one change byte per frame, everything
    # else seeked over.
    def stats : Stats
      scan { }
    end

    def decode : Stats
      check_ffmpeg!

      audio_path = File.tempname("grec_audio", ".raw")
      begin
        result = File.open(audio_path, "wb") do |audio_file|
          scan { |io, audio_len| IO.copy(io, audio_file, audio_len) }
        end
        encode(result, audio_path)
        result
      ensure
        File.delete?(audio_path)
      end
    end

    private def check_ffmpeg! : Nil
      Process.run("ffmpeg", ["-version"])
    rescue IO::Error
      raise FfmpegNotFound.new("ffmpeg not found in PATH")
    end

    # The shared pass-1 walk: yields (io, audio_len) positioned at each
    # frame's PCM so the decode path can extract it; a stats-only scan
    # yields to a block that reads nothing, and the walk seeks past
    # whatever the block left unconsumed. Stops cleanly at the footer OR
    # at a truncated tail (a crashed recorder's file still scans).
    private def scan(& : File, UInt32 -> _) : Stats
      frame_count = 0
      total_change = 0_i64
      header = uninitialized Header

      File.open(@grec_path, "rb") do |io|
        header = read_header(io)

        until io.pos == io.size
          break if at_footer?(io)

          change = io.read_byte
          break unless change
          total_change += change

          video_len = read_u32(io)
          break unless video_len
          # to_i64: a relative seek does signed arithmetic against the
          # read-buffer position internally - handing it the raw UInt32
          # overflows the moment that math needs to go negative.
          io.seek(video_len.to_i64, IO::Seek::Current)

          audio_len = read_u32(io)
          break unless audio_len
          audio_start = io.pos
          yield io, audio_len
          io.pos = audio_start + audio_len

          frame_count += 1
        end
      end

      fps = header.fps_num.to_f / header.fps_den
      Stats.new(
        frame_count: frame_count, width: header.width, height: header.height,
        fps: fps, duration: frame_count / fps,
        avg_change_pct: frame_count > 0 ? total_change.to_f / frame_count : 0.0,
        raw_video_size: frame_count.to_i64 * header.width * header.height * 4,
        audio_rate: header.audio_rate, audio_channels: header.audio_channels)
    end

    # Pass 2: decode video frames one at a time and pipe raw BGRA to
    # ffmpeg's stdin, audio coming from the pass-1 tempfile.
    private def encode(info : Stats, audio_path : String) : Nil
      process = Process.new("ffmpeg", ffmpeg_args(info, audio_path),
        input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)

      stderr = IO::Memory.new
      error_reader = spawn_reader(process.error, stderr)
      progress_reader = spawn_progress_reader(process.output, info.frame_count)

      pipe_frames(info, process.input)
      process.input.close

      status = process.wait
      error_reader.receive
      progress_reader.receive
      STDERR.print "\r\e[K" if @progress
      raise "ffmpeg failed (exit #{status.exit_code}): #{stderr}" unless status.success?
    end

    private def pipe_frames(info : Stats, stdin : IO) : Nil
      pixel_count = info.width * info.height
      prev = Slice(UInt32).new(pixel_count, 0_u32)
      frame = Slice(UInt32).new(pixel_count, 0_u32)

      File.open(@grec_path, "rb") do |io|
        io.seek(HEADER_SIZE)

        until io.pos == io.size
          break if at_footer?(io)
          break unless io.read_byte # change_pct, unused here

          video_len = read_u32(io)
          break unless video_len
          compressed = Bytes.new(video_len)
          io.read_fully(compressed)

          delta = inflate(compressed)
          raise FormatError.new("frame size mismatch") unless delta.size == pixel_count * 4
          FrameDelta.xor_into(frame, delta.to_unsafe.as(UInt32*).to_slice(pixel_count), prev)
          stdin.write(frame.to_unsafe.as(UInt8*).to_slice(pixel_count * 4))
          frame, prev = prev, frame # this frame becomes the next one's previous

          audio_len = read_u32(io)
          break unless audio_len
          io.seek(audio_len.to_i64, IO::Seek::Current) # to_i64: see #scan
        end
      end
    end

    # mGBA frames are uint32 0xAARRGGBB - byte order B-G-R-A on
    # little-endian, so ffmpeg is told bgra. -sws_flags neighbor rather
    # than scale=W:H:flags=neighbor: the inline flags= syntax produced
    # vertically-oriented output on ffmpeg 7.1.1 (ruby's own note).
    # yuv420p on output for broad player compatibility.
    private def ffmpeg_args(info : Stats, audio_path : String) : Array(String)
      args = [
        "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "bgra",
        "-s", "#{info.width}x#{info.height}",
        "-r", sprintf("%.4f", info.fps),
        "-i", "pipe:0",
        "-f", "s16le", "-ar", info.audio_rate.to_s,
        "-ac", info.audio_channels.to_s,
        "-i", audio_path,
      ]
      if (scale = @scale) && scale > 1
        args.concat(["-vf", "scale=#{info.width * scale}:#{info.height * scale}", "-sws_flags", "neighbor"])
      end
      if extra = @ffmpeg_args
        args.concat(extra)
      else
        args.concat(["-c:v", @video_codec, "-pix_fmt", "yuv420p", "-c:a", @audio_codec])
      end
      args.concat(["-progress", "pipe:1"]) if @progress
      args << @output_path
      args
    end

    # Drains an ffmpeg pipe on its own fiber (both pipes must be read
    # concurrently with the stdin writes or ffmpeg can deadlock against
    # a full pipe buffer); signals completion through the returned
    # channel.
    private def spawn_reader(from : IO, into : IO) : Channel(Nil)
      done = Channel(Nil).new
      spawn do
        IO.copy(from, into)
      rescue IO::Error
      ensure
        done.send(nil)
      end
      done
    end

    # ffmpeg's -progress key=value stream on stdout -> one updating
    # STDERR line, throttled to twice a second, ruby-style.
    private def spawn_progress_reader(from : IO, total_frames : Int32) : Channel(Nil)
      done = Channel(Nil).new
      spawn do
        current = 0
        encode_fps = 0.0
        last_print = Time.instant - 1.seconds

        from.each_line do |line|
          if value = line.lchop?("frame=")
            current = value.to_i? || current
          elsif value = line.lchop?("fps=")
            encode_fps = value.to_f? || encode_fps
          elsif line.starts_with?("progress=")
            now = Time.instant
            next unless @progress && (line.starts_with?("progress=end") || now - last_print >= 0.5.seconds)

            pct = total_frames > 0 ? current * 100.0 / total_frames : 0.0
            fps_text = encode_fps > 0 ? sprintf(" @ %.1f fps", encode_fps) : ""
            STDERR.print sprintf("\rEncoding: %d/%d (%.1f%%)%s\e[K", current, total_frames, pct, fps_text)
            last_print = now
          end
        end
      rescue IO::Error
      ensure
        done.send(nil)
      end
      done
    end

    private def read_header(io : File) : Header
      raise FormatError.new("File too small for header") if io.size < HEADER_SIZE

      magic = Bytes.new(8)
      io.read_fully(magic)
      raise FormatError.new("Invalid magic: #{String.new(magic).inspect}") unless String.new(magic) == Recorder::MAGIC

      version = io.read_byte
      raise FormatError.new("Unsupported version: #{version}") unless version == Recorder::VERSION

      header = Header.new(
        width: io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i,
        height: io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i,
        fps_num: io.read_bytes(UInt32, IO::ByteFormat::LittleEndian),
        fps_den: io.read_bytes(UInt32, IO::ByteFormat::LittleEndian),
        audio_rate: io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i,
        audio_channels: io.read_byte.try(&.to_i) || 0,
        audio_bits: io.read_byte.try(&.to_i) || 0)
      io.skip(5) # reserved
      header
    end

    # The 8-byte footer probe (u32 frame count + "GEND"), rewinding when
    # it isn't one.
    private def at_footer?(io : File) : Bool
      pos = io.pos
      probe = Bytes.new(8)
      read = io.read(probe)
      return true if read == 8 && String.new(probe[4, 4]) == Recorder::FOOTER_MAGIC

      io.pos = pos
      false
    end

    private def read_u32(io : File) : UInt32?
      raw = Bytes.new(4)
      return unless io.read(raw) == 4

      IO::ByteFormat::LittleEndian.decode(UInt32, raw)
    end

    private def inflate(compressed : Bytes) : Bytes
      Compress::Zlib::Reader.open(IO::Memory.new(compressed)) do |zlib|
        io = IO::Memory.new
        IO.copy(zlib, io)
        io.to_slice
      end
    end
  end
end
