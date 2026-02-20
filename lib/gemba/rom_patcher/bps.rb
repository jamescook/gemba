# frozen_string_literal: true

require 'zlib'
require 'stringio'

module Gemba
  class RomPatcher
    # Applies a BPS (Beat Patch System) patch.
    #
    # File layout:
    #
    #   ┌──────────────────────────────────────────────────────┐
    #   │  "BPS1"  (4 bytes, magic)                           │
    #   ├──────────────────────────────────────────────────────┤
    #   │  source_size    (varint)                            │
    #   │  target_size    (varint)                            │
    #   │  metadata_size  (varint)                            │
    #   │  metadata       (<metadata_size> bytes, skipped)   │
    #   ├──────────────────────────────────────────────────────┤
    #   │  actions …  (repeated until patch.size - 12)        │
    #   ├──────────────────────────────────────────────────────┤
    #   │  src_crc32    4B LE  │  tgt_crc32  4B LE  │ patch  │ ← footer
    #   └──────────────────────────────────────────────────────┘
    #
    # Each action word (varint):  word = (length - 1) << 2 | mode
    #
    #   mode 0  SourceRead   ┌────────┐  copy `length` bytes from source
    #                        │  word  │  at current output offset
    #                        └────────┘
    #
    #   mode 1  TargetRead   ┌────────┬──────────────────────┐
    #                        │  word  │  data  (<length> B)  │
    #                        └────────┴──────────────────────┘
    #
    #   mode 2  SourceCopy   ┌────────┬───────────┐  seek src by signed delta,
    #                        │  word  │  delta(v) │  copy `length` bytes
    #                        └────────┴───────────┘
    #
    #   mode 3  TargetCopy   ┌────────┬───────────┐  seek already-written target
    #                        │  word  │  delta(v) │  by signed delta, copy
    #                        └────────┴───────────┘
    #
    # BPS varint encoding (7-bit groups, additive-shift, differs from UPS):
    #   Each byte holds 7 data bits (b & 0x7f = 0b01111111) and one flag bit
    #   (b & 0x80).  Flag=1 means last byte; flag=0 means more follow.
    #   Unlike UPS (bitwise OR + left-shift), BPS uses multiplication and adds
    #   an extra `shift` after each non-terminal byte so that 0x00 is never a
    #   valid single-byte encoding — this lets the format distinguish "no data"
    #   from an actual zero value.
    #   value = 0, shift = 1
    #   per byte:  value += (b & 0x7f) * shift
    #              if bit7 set → done;  else shift <<= 7; value += shift
    #
    #   Example: value 300 decoded from bytes [0x2C, 0x81]
    #   raw byte  │  & 0x7f  │  shift  │  value after        │  bit7  │  action
    #   ──────────┼──────────┼─────────┼─────────────────────┼────────┼───────────────────────────
    #   0x2C      │    44    │    1    │  0 + 44×1    =  44  │   0    │  shift<<=7 (→128); value+=128 (→172)
    #   0x81      │     1    │  128    │  172 + 1×128 = 300  │   1    │  break
    class BPS
      # @param rom   [String] binary ROM data
      # @param patch [String] binary BPS patch data
      # @return [String] patched ROM (binary)
      # @raise [RuntimeError] on CRC32 mismatch
      def self.apply(rom, patch, on_progress: nil)
        raise "BPS patch too small to be valid" if patch.bytesize < 16
        rom   = rom.b
        patch = patch.b
        io = StringIO.new(patch)
        io.read(4) # "BPS1"

        read_varint(io) # source_size — not used; target_size drives allocation
        target_size   = read_varint(io)
        metadata_size = read_varint(io)
        skip = io.read(metadata_size)
        raise "Truncated BPS metadata" if skip&.bytesize != metadata_size

        target     = "\x00".b * target_size
        out_offset = 0
        src_offset = 0
        tgt_offset = 0
        patch_end  = patch.bytesize - 12

        last_pct = -1

        while io.pos < patch_end
          if on_progress
            pct = (io.pos / patch_end.to_f * 100).floor
            if pct != last_pct
              on_progress.call(pct / 100.0)
              last_pct = pct
            end
          end

          word   = read_varint(io)
          mode   = word & 3
          length = (word >> 2) + 1

          case mode
          when 0 # SourceRead — copy from rom at current out position
            length.times do
              target.setbyte(out_offset, rom.getbyte(out_offset) || 0)
              out_offset += 1
            end
          when 1 # TargetRead — literal data
            data = io.read(length)
            target[out_offset, length] = data
            out_offset += length
          when 2 # SourceCopy — relative seek in source
            src_offset += read_signed_varint(io)
            length.times do
              target.setbyte(out_offset, rom.getbyte(src_offset) || 0)
              out_offset += 1
              src_offset += 1
            end
          when 3 # TargetCopy — relative seek in target
            tgt_offset += read_signed_varint(io)
            length.times do
              target.setbyte(out_offset, target.getbyte(tgt_offset) || 0)
              out_offset += 1
              tgt_offset += 1
            end
          end
        end

        raise "BPS patch too small to contain footer" if patch.bytesize < 12
        src_crc, tgt_crc = patch[-12..].unpack("VV")
        raise "BPS source CRC32 mismatch" unless Zlib.crc32(rom)    == src_crc
        raise "BPS target CRC32 mismatch" unless Zlib.crc32(target) == tgt_crc

        target
      end

      # BPS varint: low 7 bits per byte; bit7=1 terminates; additive shift encoding.
      # Decoder: value = 0, shift = 1; per byte: value += (b & 0x7f) * shift;
      #          if bit7: break; else: shift <<= 7; value += shift.
      def self.read_varint(io)
        value = 0
        shift = 1
        loop do
          byte = io.read(1)
          raise "Truncated BPS patch (varint read past end)" if byte.nil?
          b      = byte.getbyte(0)
          value += (b & 0x7f) * shift
          break if (b & 0x80) != 0
          shift <<= 7
          value += shift
        end
        value
      end
      private_class_method :read_varint

      def self.read_signed_varint(io)
        v        = read_varint(io)
        negative = (v & 1) != 0
        v >>= 1
        negative ? -v : v
      end
      private_class_method :read_signed_varint
    end
  end
end
