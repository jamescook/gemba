# frozen_string_literal: true

module Gemba
  # Replays a .gir (Gemba Input Recording) file by feeding recorded
  # per-frame bitmasks back to the emulator core.
  #
  # The authoritative frame count comes from counting bitmask lines,
  # not the header (which is best-effort and may be zero on crash).
  #
  # @example
  #   replayer = InputReplayer.new("session.gir")
  #   replayer.validate!(core)
  #   core.load_state_from_file(replayer.anchor_state_path)
  #   replayer.each_bitmask do |mask, frame|
  #     core.set_keys(mask)
  #     core.run_frame
  #   end
  class InputReplayer
    class ChecksumMismatch < StandardError; end

    # @param gir_path [String] path to .gir file
    def initialize(gir_path)
      @path = gir_path
      @header = {}
      @bitmasks = []
      parse!
    end

    # @return [Integer] ROM checksum from the recording header
    def rom_checksum
      @header[:rom_checksum]
    end

    # @return [String] game code from the recording header
    def game_code
      @header[:game_code]
    end

    # @return [String, nil] ROM path from the recording header
    def rom_path
      @header[:rom_path]
    end

    # @return [Integer] number of recorded frames (counted from bitmask lines)
    def frame_count
      @bitmasks.length
    end

    # @return [String] path to the anchor save state file
    def anchor_state_path
      dir = File.dirname(@path)
      File.join(dir, @header[:anchor_state])
    end

    # Validate that the recording matches the loaded ROM.
    # @param core [Gemba::Core] mGBA core to validate against
    # @raise [ChecksumMismatch] if ROM checksum doesn't match
    def validate!(core)
      if rom_checksum && core.checksum != rom_checksum
        raise ChecksumMismatch,
          "ROM checksum mismatch: recording has #{rom_checksum}, " \
          "loaded ROM has #{core.checksum}"
      end
    end

    # @param frame [Integer] zero-based frame index
    # @return [Integer] bitmask for the given frame
    def bitmask_at(frame)
      @bitmasks[frame]
    end

    # Iterate over all recorded bitmasks.
    # @yield [Integer, Integer] bitmask and zero-based frame index
    def each_bitmask(&block)
      @bitmasks.each_with_index(&block)
    end

    private

    def parse!
      in_header = true

      File.foreach(@path) do |line|
        line = line.strip

        if in_header
          if line == '---'
            in_header = false
          elsif line.start_with?('# ')
            parse_header_line(line)
          end
        else
          next if line.empty?
          @bitmasks << line.to_i(16)
        end
      end
    end

    def parse_header_line(line)
      # Format: "# key: value"
      content = line.sub(/^# /, '')
      key, _, value = content.partition(': ')
      return if value.empty?

      case key
      when 'rom_checksum'
        @header[:rom_checksum] = value.to_i
      when 'game_code'
        @header[:game_code] = value
      when 'anchor_state'
        @header[:anchor_state] = value
      when 'rom_path'
        @header[:rom_path] = value
      when 'frame_count'
        @header[:header_frame_count] = value.to_i
      end
    end
  end
end
