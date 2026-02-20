# frozen_string_literal: true

require 'stringio'

module Gemba
  class RomPatcher
    # Applies an IPS (International Patching System) patch.
    #
    # File layout:
    #
    #   ┌─────────────────────────────────────────────┐
    #   │  "PATCH"  (5 bytes, magic)                  │
    #   ├─────────────────────────────────────────────┤
    #   │  Record 1                                   │
    #   │  Record 2                                   │
    #   │  ...                                        │
    #   ├─────────────────────────────────────────────┤
    #   │  "EOF"  (3 bytes, terminator)               │
    #   └─────────────────────────────────────────────┘
    #
    # Record formats:
    #
    #   Normal record:
    #   ┌────────────────────┬───────────────────┬─────────────────────┐
    #   │ offset             │  size             │  data               │
    #   │ 3 bytes, big-endian│ 2 bytes, big-endian│  <size> bytes      │
    #   └────────────────────┴───────────────────┴─────────────────────┘
    #
    #   RLE record — size field is 0x0000 (zero), which is the signal that
    #   this is NOT a normal data record. Instead of inline bytes, the next
    #   two fields say "repeat one byte N times":
    #   ┌────────────────────┬──────────┬────────────────────┬──────────┐
    #   │ offset             │  0x0000  │  count             │  value   │
    #   │ 3 bytes, big-endian│  2 bytes │ 2 bytes, big-endian│  1 byte  │
    #   └────────────────────┴──────────┴────────────────────┴──────────┘
    #   Writes `value` repeated `count` times starting at `offset`.
    #   e.g. offset=0x100, count=8, value=0xFF → fills 8 bytes with 0xFF.
    #
    # No checksums — no integrity verification.
    class IPS
      EOF_MARKER = "EOF".b.freeze

      # @param rom   [String] binary ROM data
      # @param patch [String] binary IPS patch data
      # @return [String] patched ROM (binary)
      def self.apply(rom, patch, on_progress: nil)
        rom   = rom.b
        patch = patch.b
        result = rom.dup
        io = StringIO.new(patch)
        read!(io, 5) # "PATCH"

        total    = patch.bytesize.to_f
        last_pct = -1

        loop do
          offset_bytes = io.read(3)
          break if offset_bytes.nil? || offset_bytes == EOF_MARKER
          raise "Truncated patch: incomplete offset record" if offset_bytes.bytesize < 3

          offset = (offset_bytes.getbyte(0) << 16) |
                   (offset_bytes.getbyte(1) << 8)  |
                    offset_bytes.getbyte(2)

          size = read!(io, 2).unpack1("n")  # "n" = 16-bit unsigned big-endian

          data = if size == 0
                   count = read!(io, 2).unpack1("n")  # "n" = 16-bit unsigned big-endian
                   value = read!(io, 1)
                   value * count
                 else
                   read!(io, size)
                 end

          # Extend ROM if patch writes past current end
          needed = offset + data.bytesize
          result << "\x00".b * (needed - result.bytesize) if needed > result.bytesize
          result[offset, data.bytesize] = data

          if on_progress
            pct = (io.pos / total * 100).floor
            if pct != last_pct
              on_progress.call(pct / 100.0)
              last_pct = pct
            end
          end
        end

        result
      end

      def self.read!(io, n)
        data = io.read(n)
        raise "Truncated IPS patch (expected #{n} bytes, got #{data&.bytesize || 0})" \
          if data.nil? || data.bytesize < n
        data
      end
      private_class_method :read!
    end
  end
end
