require "json"
require "./core"

module Gemba
  # What EmulationWorker reports back once Core has loaded - the ROM
  # header fields RomInfoWindow displays. Core is thread-confined to
  # the worker (see EmulationWorker's own class comment), so this
  # crosses to the main thread as a JSON payload rather than a direct
  # Core call.
  struct RomInfoData
    include JSON::Serializable

    getter title : String
    getter game_code : String
    getter maker_code : String
    getter platform : String
    getter rom_size : UInt64
    getter checksum : UInt32
    getter width : Int32
    getter height : Int32

    def initialize(@title, @game_code, @maker_code, @platform, @rom_size, @checksum, @width, @height)
    end

    # ROM header offset for the 2-char ASCII maker code (0x080000B0/B1);
    # read directly since this is the only caller.
    MAKER_CODE_OFFSET = 0x080000B0_u32

    def self.from_core(core : Core) : RomInfoData
      maker = begin
        a = core.bus_read8(MAKER_CODE_OFFSET).chr
        b = core.bus_read8(MAKER_CODE_OFFSET + 1).chr
        "#{a}#{b}"
      rescue
        ""
      end

      new(
        title: core.title, game_code: core.game_code, maker_code: maker,
        platform: platform_name(core.platform), rom_size: core.rom_size,
        checksum: core.checksum, width: core.width, height: core.height,
      )
    end

    private def self.platform_name(platform : LibMgba::Platform) : String
      case platform
      when LibMgba::Platform::GBA then "Game Boy Advance"
      else                             platform.to_s
      end
    end
  end
end
