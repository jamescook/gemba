# frozen_string_literal: true

require 'zlib'
require 'stringio'

module Gemba
  class RomPatcher
    # Applies a UPS (Universal Patching System) patch.
    #
    # File layout:
    #
    #   ┌──────────────────────────────────────────────────────┐
    #   │  "UPS1"  (4 bytes, magic)                           │
    #   ├──────────────────────────────────────────────────────┤
    #   │  source_size  (varint)                              │
    #   │  target_size  (varint)                              │
    #   ├──────────────────────────────────────────────────────┤
    #   │  hunks …  (repeated until patch.size - 12)          │
    #   ├──────────────────────────────────────────────────────┤
    #   │  src_crc32  4B LE  │  tgt_crc32  4B LE  │  patch   │ ← footer
    #   └──────────────────────────────────────────────────────┘
    #
    # Each hunk:
    #   ┌──────────────────┬──────────────────────────────────┐
    #   │  skip  (varint)  │  xor_data …  0x00                │
    #   └──────────────────┴──────────────────────────────────┘
    #
    #   skip     — advance output position by this many bytes (unchanged bytes)
    #   xor_data — each byte XOR'd with the corresponding output byte; 0x00 ends the run
    #
    # Example: source  = [AA BB CC DD EE FF]
    #          hunk 1:  skip=1, xor=[11 22], 0x00
    #          result:  [AA (BB^11) (CC^22) DD EE FF]
    #                        ↑ changed  ↑ changed
    #
    # UPS varint encoding (7-bit groups, LSB first):
    #   Each byte holds 7 data bits (b & 0x7f = 0b01111111) and one flag bit
    #   (b & 0x80).  Flag=1 means this is the last byte; flag=0 means more follow.
    #   value = 0, shift = 0
    #   per byte:  value |= (b & 0x7f) << shift
    #              if bit7 set → done;  else shift += 7
    #
    #   Example: value 300 decoded from bytes [0x2C, 0x82]
    #   raw byte  │  & 0x7f  │  shift  │  value after          │  bit7  │  action
    #   ──────────┼──────────┼─────────┼───────────────────────┼────────┼──────────
    #   0x2C      │   0x2C   │   0     │  0x2C        (44)     │   0    │  shift += 7
    #   0x82      │   0x02   │   7     │  0x2C│0x100  (300)    │   1    │  break
    class UPS
      # @param rom   [String] binary ROM data
      # @param patch [String] binary UPS patch data
      # @return [String] patched ROM (binary)
      # @raise [RuntimeError] on CRC32 mismatch
      def self.apply(rom, patch, on_progress: nil)
        rom   = rom.b
        patch = patch.b
        io = StringIO.new(patch)
        io.read(4) # "UPS1"

        read_varint(io) # source_size — not needed; we derive target from target_size
        target_size  = read_varint(io)

        result = if rom.bytesize >= target_size
                   rom[0, target_size].dup
                 else
                   rom + "\x00".b * (target_size - rom.bytesize)
                 end

        pos       = 0
        patch_end = patch.bytesize - 12
        last_pct  = -1

        while io.pos < patch_end
          if on_progress
            pct = (io.pos / patch_end.to_f * 100).floor
            if pct != last_pct
              on_progress.call(pct / 100.0)
              last_pct = pct
            end
          end

          pos += read_varint(io)

          while io.pos < patch_end
            b = io.read(1).getbyte(0)
            break if b == 0x00
            result.setbyte(pos, (result.getbyte(pos) || 0) ^ b) if pos < result.bytesize
            pos += 1
          end
          pos += 1 # advance past the matching byte at the hunk boundary
        end

        src_crc, tgt_crc = patch[-12..].unpack("VV")
        raise "UPS source CRC32 mismatch" unless Zlib.crc32(rom)    == src_crc
        raise "UPS target CRC32 mismatch" unless Zlib.crc32(result) == tgt_crc

        result
      end

      # UPS varint: low 7 bits per byte; bit7=1 terminates; simple bitshift accumulation.
      # Decoder: value = 0, shift = 0; per byte: value |= (b & 0x7f) << shift;
      #          if bit7: break; else: shift += 7.
      def self.read_varint(io)
        value = 0
        shift = 0
        loop do
          byte = io.read(1)
          raise "Truncated UPS patch (varint read past end)" if byte.nil?
          b      = byte.getbyte(0)
          value |= (b & 0x7f) << shift
          break if (b & 0x80) != 0
          shift += 7
        end
        value
      end
      private_class_method :read_varint
    end
  end
end
