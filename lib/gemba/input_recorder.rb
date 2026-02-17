# frozen_string_literal: true

module Gemba
  # Records per-frame input bitmasks to a .gir (Gemba Input Recording) file.
  #
  # Each GBA frame's pressed-button bitmask is stored as a 3-char hex line.
  # An anchor save state is written alongside so replays start from the
  # exact same emulator state.
  #
  # The header's frame_count is a best-effort hint (correct on clean stop,
  # zero on crash). The replayer counts lines for the authoritative count.
  #
  # @example
  #   recorder = InputRecorder.new("session.gir", core: core)
  #   recorder.start
  #   loop do
  #     mask = poll_input
  #     recorder.capture(mask)
  #     core.set_keys(mask)
  #     core.run_frame
  #   end
  #   recorder.stop
  class InputRecorder
    VERSION = 1
    FLUSH_INTERVAL = 60 # frames between flushes (~1s at 59.7 fps)

    # @param path [String] output .gir file path
    # @param core [Gemba::Core] mGBA core (for ROM metadata and save state)
    # @param rom_path [String, nil] path to the ROM file (stored in header for easy replay)
    def initialize(path, core:, rom_path: nil)
      @path = path
      @core = core
      @rom_path = rom_path
      @recording = false
      @frame_count = 0
    end

    # Start recording. Saves an anchor save state and opens the .gir file.
    def start
      raise "Already recording" if @recording

      @core.save_state_to_file(anchor_state_path)
      @frame_count = 0
      @file = File.open(@path, 'w')
      write_header
      @file.flush
      @recording = true
    end

    # Capture one frame's input bitmask.
    # @param bitmask [Integer] bitwise OR of KEY_* constants (0x000–0x3FF)
    def capture(bitmask)
      return unless @recording

      @file.puts(format('%03x', bitmask & 0x3FF))
      @frame_count += 1
      @file.flush if (@frame_count % FLUSH_INTERVAL).zero?
    end

    # Stop recording and close the file.
    def stop
      return unless @recording

      @recording = false
      rewrite_frame_count
      @file.close
      @file = nil
    end

    # @return [Boolean] true if currently recording
    def recording?
      @recording
    end

    # @return [Integer] number of frames captured so far
    attr_reader :frame_count

    # @return [String] path to the anchor save state file
    def anchor_state_path
      @path.sub(/\.gir\z/, '.state')
    end

    private

    FRAME_COUNT_WIDTH = 10 # zero-padded digits (covers ~5.3 years at 60fps)

    def write_header
      @file.puts "# GEMBA INPUT RECORDING v#{VERSION}"
      @file.puts "# rom_checksum: #{@core.checksum}"
      @file.puts "# game_code: #{@core.game_code}"
      @file.puts "# rom_path: #{@rom_path}" if @rom_path
      @file.write "# frame_count: "
      @frame_count_offset = @file.pos
      @file.puts format("%0#{FRAME_COUNT_WIDTH}d", 0)
      @file.puts "# anchor_state: #{File.basename(anchor_state_path)}"
      @file.puts "---"
    end

    # Best-effort: seek to the frame_count field and overwrite in place.
    def rewrite_frame_count
      @file.flush
      @file.seek(@frame_count_offset)
      @file.write(format("%0#{FRAME_COUNT_WIDTH}d", @frame_count))
      @file.seek(0, IO::SEEK_END)
    end
  end
end
