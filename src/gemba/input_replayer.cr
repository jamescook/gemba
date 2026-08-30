require "./core"

module Gemba
  # Replays a .gir (Gemba Input Recording) file - see InputRecorder for
  # the format, which ruby gemba's recordings share - by handing the
  # recorded per-frame bitmasks back one at a time.
  #
  # The authoritative frame count comes from counting mask lines, not
  # the header (whose count is best-effort and stays zero if the
  # recorder crashed before its clean stop).
  #
  # Pure parsing plus a checksum check - no Tk, no threads - so it works
  # anywhere a Core does: the replay viewer, a CLI command, or a
  # determinism spec feeding a headless Core directly:
  #
  #     replayer = InputReplayer.new("session.gir")
  #     replayer.validate!(core)
  #     core.load_state_from_file(replayer.anchor_state_path)
  #     replayer.each_bitmask do |mask, _frame|
  #       core.keys = mask
  #       core.run_frame
  #     end
  class InputReplayer
    class ChecksumMismatch < Exception; end

    getter rom_checksum : UInt32?
    getter game_code : String?
    getter rom_path : String?

    # The header's own (best-effort) count - #frame_count is the real one.
    getter header_frame_count : Int32?

    def initialize(@path : String)
      @bitmasks = [] of UInt32
      @anchor_state = nil.as(String?)
      parse!
    end

    def frame_count : Int32
      @bitmasks.size
    end

    # Resolved relative to the .gir's own directory, same as the
    # recorder wrote it. Falls back to the recorder's naming convention
    # if the header line is missing (a truncated file).
    def anchor_state_path : String
      dir = File.dirname(@path)
      name = @anchor_state || File.basename(@path).sub(/\.gir\z/, ".state")
      File.join(dir, name)
    end

    # Raises ChecksumMismatch unless the loaded ROM is the one this was
    # recorded against. A recording with no checksum header passes -
    # nothing to check against.
    def validate!(core : Core) : Nil
      recorded = rom_checksum
      return if recorded.nil? || core.checksum == recorded

      raise ChecksumMismatch.new(
        "ROM checksum mismatch: recording has #{recorded}, loaded ROM has #{core.checksum}")
    end

    def bitmask_at(frame : Int32) : UInt32
      @bitmasks[frame]
    end

    def each_bitmask(& : UInt32, Int32 -> _) : Nil
      @bitmasks.each_with_index { |mask, frame| yield mask, frame }
    end

    private def parse! : Nil
      in_header = true

      File.each_line(@path) do |raw|
        line = raw.strip

        if in_header
          if line == "---"
            in_header = false
          elsif line.starts_with?("# ")
            parse_header_line(line)
          end
        elsif !line.empty?
          @bitmasks << line.to_u32(base: 16)
        end
      end
    end

    private def parse_header_line(line : String) : Nil
      key, _, value = line.lchop("# ").partition(": ")
      return if value.empty?

      case key
      when "rom_checksum" then @rom_checksum = value.to_u32?
      when "game_code"    then @game_code = value
      when "anchor_state" then @anchor_state = value
      when "rom_path"     then @rom_path = value
      when "frame_count"  then @header_frame_count = value.to_i?
      end
    end
  end
end
