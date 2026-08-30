require "./core"

module Gemba
  # Records per-frame input bitmasks to a .gir (Gemba Input Recording)
  # file - the same on-disk format ruby gemba writes, so recordings are
  # portable between the two.
  #
  # Each emulated frame's pressed-button bitmask is stored as a 3-char
  # hex line. An anchor save state is written alongside (#start) so
  # replays begin from the exact same emulator state.
  #
  # The header's frame_count is a best-effort hint: rewritten in place
  # on a clean #stop, left zero on a crash. InputReplayer counts mask
  # lines for the authoritative number.
  #
  # Lives WHEREVER its Core lives - in the running app that means the
  # EmulationWorker's own thread (Core is worker-thread-only, and
  # #capture happens once per emulated frame, right where the mask is
  # applied); a headless harness can drive one directly on any thread
  # that owns the Core.
  class InputRecorder
    VERSION        =  1
    FLUSH_INTERVAL = 60 # frames between flushes (~1s at 59.7 fps)

    # Zero-padded digits reserved for the in-place frame_count rewrite
    # (covers ~5.3 years of frames at 60fps).
    FRAME_COUNT_WIDTH = 10

    getter frame_count : Int32 = 0

    @file : File?

    # rom_path is stored in the header purely as a convenience for
    # replay tooling - the checksum is what actually identifies the ROM.
    def initialize(@path : String, @core : Core, @rom_path : String? = nil)
      @recording = false
      @frame_count_offset = 0_i64
    end

    # Saves the anchor save state and opens the .gir file. Raises if the
    # anchor state can't be written (libmgba reporting failure included)
    # - a recording with no anchor could never replay from the right
    # starting point, so there's nothing useful to fall back to.
    def start : Nil
      raise "Already recording" if @recording
      raise "cannot write anchor state: #{anchor_state_path}" unless @core.save_state_to_file(anchor_state_path)

      @frame_count = 0
      file = File.new(@path, "w")
      @file = file
      write_header(file)
      file.flush
      @recording = true
    end

    # Captures one frame's input bitmask - call once per emulated frame,
    # with the mask that frame actually ran under.
    def capture(bitmask : UInt32) : Nil
      return unless @recording
      file = @file
      return unless file

      file.puts(sprintf("%03x", bitmask & 0x3FF))
      @frame_count += 1
      file.flush if (@frame_count % FLUSH_INTERVAL).zero?
    end

    # Stops recording, rewrites the header's frame_count in place and
    # closes the file.
    def stop : Nil
      return unless @recording

      @recording = false
      if file = @file
        rewrite_frame_count(file)
        file.close
      end
      @file = nil
    end

    def recording? : Bool
      @recording
    end

    # The sibling save-state file replays start from - session.gir gets
    # session.state, matching ruby gemba.
    def anchor_state_path : String
      @path.sub(/\.gir\z/, ".state")
    end

    private def write_header(file : File) : Nil
      file.puts "# GEMBA INPUT RECORDING v#{VERSION}"
      file.puts "# rom_checksum: #{@core.checksum}"
      file.puts "# game_code: #{@core.game_code}"
      if rom_path = @rom_path
        file.puts "# rom_path: #{rom_path}"
      end
      file.print "# frame_count: "
      file.flush
      @frame_count_offset = file.pos
      file.puts sprintf("%0#{FRAME_COUNT_WIDTH}d", 0)
      file.puts "# anchor_state: #{File.basename(anchor_state_path)}"
      file.puts "---"
    end

    # Best-effort: seek back to the frame_count field and overwrite the
    # zero-padded placeholder in place.
    private def rewrite_frame_count(file : File) : Nil
      file.flush
      file.seek(@frame_count_offset)
      file.print sprintf("%0#{FRAME_COUNT_WIDTH}d", @frame_count)
      file.seek(0, IO::Seek::End)
    end
  end
end
