require "compress/zlib"
require "./frame_delta"

module Gemba
  # Records emulator video + audio to a .grec file - the same on-disk
  # format ruby gemba's Recorder writes, byte for byte, so either app's
  # tools can decode the other's recordings.
  #
  # Layout: a 32-byte header ("GEMBAREC", version, dimensions, fps as a
  # numerator/denominator fraction, audio spec), then per frame a
  # change-percentage byte, the zlib-compressed XOR delta against the
  # previous frame (length-prefixed), and that frame's raw s16le PCM
  # (length-prefixed), then an 8-byte footer (frame count + "GEND").
  # All integers little-endian.
  #
  # Video goes in RAW - core.video_buffer's own 0xAARRGGBB words (BGRA
  # byte order in memory on little-endian, which is what the decoder
  # tells ffmpeg), NOT the color-corrected/blended frame FramePainter
  # shows on screen. Same choice ruby makes, and the one that keeps the
  # recorder on the worker thread where the frames already are.
  #
  # Threading: #capture runs on whatever thread owns the Core (the
  # EmulationWorker thread in the app) and does the XOR + zlib there -
  # cheap at level 1 - but hands finished byte batches to a dedicated
  # writer thread (Fiber::ExecutionContext::Isolated + Channel, this
  # port's stand-in for ruby's Thread + Thread::Queue) so disk latency
  # never stalls the frame loop. #stop flushes, writes the footer and
  # joins the writer before returning.
  class Recorder
    MAGIC          = "GEMBAREC"
    FOOTER_MAGIC   = "GEND"
    VERSION        =  1_u8
    AUDIO_BITS     = 16_u8
    FLUSH_INTERVAL =    60 # frames per batch handed to the writer (~1s)

    # GBA clock / cycles-per-frame, matching ruby's Platform::GBA
    # fps_fraction - stored in the header so a decoder reproduces the
    # exact 59.7275... rate rather than a rounded one.
    GBA_FPS_FRACTION = {262144_u32, 4389_u32}

    getter frame_count : Int32 = 0

    @queue : Channel(Bytes?)?
    @writer_done : Channel(Nil)?

    # compression is a zlib level (1-9; 1 = fastest, the default and
    # what Config#recording_compression stores). width/height in pixels;
    # fps_fraction as {numerator, denominator}.
    def initialize(@path : String, @width : Int32, @height : Int32,
                   @fps_fraction : Tuple(UInt32, UInt32) = GBA_FPS_FRACTION,
                   @audio_rate : Int32 = 44100, @audio_channels : Int32 = 2,
                   @compression : Int32 = 1)
      @frame_size = @width * @height
      @prev_frame = Slice(UInt32).new(@frame_size, 0_u32)
      @delta = Slice(UInt32).new(@frame_size, 0_u32)
      @batch = IO::Memory.new
      @batch_frames = 0
      @recording = false
    end

    # Opens the writer thread and queues the header. Raises if already
    # recording.
    def start : Nil
      raise "Already recording" if @recording

      @frame_count = 0
      @batch_frames = 0
      @batch.clear
      @prev_frame.fill(0_u32)
      queue = Channel(Bytes?).new(64)
      done = Channel(Nil).new
      @queue = queue
      @writer_done = done
      path = @path
      Fiber::ExecutionContext::Isolated.new("Gemba::Recorder") { writer_loop(path, queue, done) }
      queue.send(build_header)
      @recording = true
    end

    # Captures one frame. video is the core's raw frame (width*height
    # 0xAARRGGBB words); audio the PCM drained for this frame - pass
    # every frame's audio, turbo included (the recording keeps
    # full-rate audio even when playback is discarding most of it).
    # Both are copied out synchronously - safe to reuse the buffers the
    # moment this returns.
    def capture(video : Slice(UInt32), audio : Slice(Int16)) : Nil
      return unless @recording

      FrameDelta.xor_into(@delta, video, @prev_frame)
      video.copy_to(@prev_frame)

      changed = FrameDelta.count_changed_pixels(@delta)
      change_pct = @frame_size > 0 ? (changed * 100 // @frame_size).clamp(0, 100) : 0

      compressed = deflate(@delta)
      audio_bytes = audio.to_unsafe.as(UInt8*).to_slice(audio.size * 2)

      @batch.write_byte(change_pct.to_u8)
      @batch.write_bytes(compressed.size.to_u32, IO::ByteFormat::LittleEndian)
      @batch.write(compressed)
      @batch.write_bytes(audio_bytes.size.to_u32, IO::ByteFormat::LittleEndian)
      @batch.write(audio_bytes)

      @frame_count += 1
      @batch_frames += 1
      flush_batch if @batch_frames >= FLUSH_INTERVAL
    end

    # Flushes what's pending, queues the footer and waits for the
    # writer thread to finish the file - once this returns, the .grec
    # is complete on disk.
    def stop : Nil
      return unless @recording
      @recording = false

      flush_batch
      if queue = @queue
        queue.send(build_footer)
        queue.send(nil)
      end
      @writer_done.try(&.receive)
      @queue = nil
      @writer_done = nil
    end

    def recording? : Bool
      @recording
    end

    private def flush_batch : Nil
      return if @batch_frames.zero?

      @queue.try(&.send(@batch.to_slice.dup))
      @batch.clear
      @batch_frames = 0
    end

    private def deflate(delta : Slice(UInt32)) : Bytes
      bytes = delta.to_unsafe.as(UInt8*).to_slice(delta.size * 4)
      io = IO::Memory.new
      Compress::Zlib::Writer.open(io, level: @compression, &.write(bytes))
      io.to_slice
    end

    private def build_header : Bytes
      io = IO::Memory.new(32)
      io.write(MAGIC.to_slice)                                         # 8
      io.write_byte(VERSION)                                           # 1
      io.write_bytes(@width.to_u16, IO::ByteFormat::LittleEndian)      # 2
      io.write_bytes(@height.to_u16, IO::ByteFormat::LittleEndian)     # 2
      io.write_bytes(@fps_fraction[0], IO::ByteFormat::LittleEndian)   # 4
      io.write_bytes(@fps_fraction[1], IO::ByteFormat::LittleEndian)   # 4
      io.write_bytes(@audio_rate.to_u32, IO::ByteFormat::LittleEndian) # 4
      io.write_byte(@audio_channels.to_u8)                             # 1
      io.write_byte(AUDIO_BITS)                                        # 1
      5.times { io.write_byte(0_u8) }                                  # 5 reserved
      io.to_slice
    end

    private def build_footer : Bytes
      io = IO::Memory.new(8)
      io.write_bytes(@frame_count.to_u32, IO::ByteFormat::LittleEndian)
      io.write(FOOTER_MAGIC.to_slice)
      io.to_slice
    end

    # Runs on the dedicated writer thread. A write error (full disk)
    # is warned and swallowed, same as ruby - it's a lost recording,
    # not a reason to take the emulator down - but the loop keeps
    # draining so #stop's join never deadlocks.
    private def writer_loop(path : String, queue : Channel(Bytes?), done : Channel(Nil)) : Nil
      file = File.new(path, "wb")
      begin
        while chunk = queue.receive
          file.write(chunk)
          # Push each batch through to the OS as it arrives - File's
          # own buffer would otherwise hold everything under 8KB (a
          # crash would lose it, and nothing observable hits disk
          # until well into a recording).
          file.flush
        end
      ensure
        file.close
      end
    rescue ex
      STDERR.puts "gemba: recorder write error: #{ex.message}"
      while queue.receive; end
    ensure
      done.send(nil)
    end
  end
end
