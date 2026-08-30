require "digest/crc32"

module Gemba
  # Applies IPS, BPS, or UPS patch files to GBA ROM files. Tk-free -
  # shared by the patcher window and the CLI patch command.
  #
  # Format support:
  #   IPS  - simplest; no checksums; RLE support
  #   BPS  - Beat Patch System; delta encoding with CRC32 verification
  #   UPS  - Universal Patching System; XOR hunks with CRC32 verification
  #
  # Usage:
  #   RomPatcher.patch(rom_path: "game.gba", patch_path: "fix.ips", out_path: "patched.gba")
  #   # or invoke a format module directly:
  #   RomPatcher::IPS.apply(rom_bytes, patch_bytes)  # => patched Bytes
  #
  # Unlike ruby gemba there is no .zip ROM input here - this port has
  # no RomResolver; callers hand in a bare ROM file.
  module RomPatcher
    # Unknown format, truncated patch data, CRC32 mismatch.
    class Error < Exception
    end

    CHUNK = 256 * 1024 # 256 KB

    alias Progress = Float64 -> Nil

    # Auto-detect format, apply patch, write output file.
    #
    # Progress budget (same as ruby's):
    #   0-15%   read ROM
    #   15-25%  read patch
    #   25-90%  format apply (IPS/BPS/UPS)
    #   90-100% write output
    #
    # Returns out_path. Raises Error on unknown format, truncation or
    # checksum failure. format: :ips/:bps/:ups forces a parser instead
    # of magic-byte auto-detection (the CLI's --format override).
    def self.patch(rom_path : String, patch_path : String, out_path : String,
                   on_progress : Progress? = nil, format : Symbol? = nil) : String
      rom = read_chunked(rom_path, 0.0, 0.15, on_progress)
      patch = read_chunked(patch_path, 0.15, 0.25, on_progress)

      chosen = format || detect_format(patch) ||
               raise Error.new("Unknown patch format (expected IPS/BPS/UPS magic)")

      apply_cb = on_progress.try do |progress|
        ->(pct : Float64) { progress.call(0.25 + pct * 0.65) }
      end
      result = case chosen
               when :ips then IPS.apply(rom, patch, on_progress: apply_cb)
               when :bps then BPS.apply(rom, patch, on_progress: apply_cb)
               when :ups then UPS.apply(rom, patch, on_progress: apply_cb)
               else           raise Error.new("Unknown patch format: #{chosen}")
               end
      on_progress.try(&.call(0.90))

      Dir.mkdir_p(File.dirname(out_path))
      write_chunked(out_path, result, 0.90, 1.0, on_progress)
      on_progress.try(&.call(1.0))
      out_path
    end

    # :ips / :bps / :ups by magic bytes, or nil.
    def self.detect_format(patch : Bytes) : Symbol?
      return :ips if starts_with?(patch, "PATCH")
      return :bps if starts_with?(patch, "BPS1")
      return :ups if starts_with?(patch, "UPS1")
      nil
    end

    # Return a path that does not collide with existing files.
    # If path exists, appends -(2), -(3), ... before the extension.
    def self.safe_out_path(path : String) : String
      return path unless File.exists?(path)
      ext = File.extname(path)
      base = path.rchop(ext)
      n = 2
      loop do
        candidate = "#{base}-(#{n})#{ext}"
        return candidate unless File.exists?(candidate)
        n += 1
      end
    end

    private def self.starts_with?(data : Bytes, magic : String) : Bool
      m = magic.to_slice
      data.size >= m.size && data[0, m.size] == m
    end

    # Read a file in chunks, reporting progress from pct_start to pct_end.
    private def self.read_chunked(path : String, pct_start : Float64, pct_end : Float64,
                                  on_progress : Progress?) : Bytes
      size = File.size(path).to_f
      buf = IO::Memory.new
      File.open(path) do |file|
        chunk = Bytes.new(CHUNK)
        while (n = file.read(chunk)) > 0
          buf.write(chunk[0, n])
          if on_progress && size > 0
            on_progress.call(pct_start + (buf.size / size) * (pct_end - pct_start))
          end
        end
      end
      buf.to_slice
    end

    # Write bytes to a file in chunks, reporting progress from pct_start to pct_end.
    private def self.write_chunked(path : String, data : Bytes, pct_start : Float64,
                                   pct_end : Float64, on_progress : Progress?) : Nil
      size = data.size.to_f
      written = 0
      File.open(path, "w") do |file|
        while written < data.size
          n = Math.min(CHUNK, data.size - written)
          file.write(data[written, n])
          written += n
          if on_progress && size > 0
            on_progress.call(pct_start + (written / size) * (pct_end - pct_start))
          end
        end
      end
    end

    # Applies an IPS (International Patching System) patch.
    #
    # File layout: "PATCH" magic, then records until an "EOF" terminator.
    #
    #   Normal record: offset (3B big-endian) | size (2B big-endian) | <size> data bytes
    #   RLE record:    offset (3B big-endian) | 0x0000 | count (2B big-endian) | value (1B)
    #                  writes `value` repeated `count` times at `offset`.
    #
    # No checksums - no integrity verification.
    module IPS
      EOF_MARKER = "EOF".to_slice

      # Returns the patched ROM. The result grows past the ROM's size
      # (zero-filled) when a record writes beyond its end.
      def self.apply(rom : Bytes, patch : Bytes, on_progress : RomPatcher::Progress? = nil) : Bytes
        io = IO::Memory.new(patch, writable: false)
        read!(io, 5) # "PATCH"

        result = Bytes.new(rom.size)
        rom.copy_to(result)

        total = patch.size.to_f
        last_pct = -1

        loop do
          offset_bytes = Bytes.new(3)
          n = io.read(offset_bytes)
          break if n == 0 || offset_bytes[0, n] == EOF_MARKER
          raise Error.new("Truncated patch: incomplete offset record") if n < 3

          offset = (offset_bytes[0].to_i32 << 16) | (offset_bytes[1].to_i32 << 8) | offset_bytes[2]
          size = read_u16(io)

          data = if size == 0
                   count = read_u16(io)
                   value = read!(io, 1)[0]
                   Bytes.new(count.to_i32, value)
                 else
                   read!(io, size.to_i32)
                 end

          # Extend ROM if patch writes past current end
          needed = offset + data.size
          if needed > result.size
            grown = Bytes.new(needed)
            result.copy_to(grown)
            result = grown
          end
          data.copy_to(result[offset, data.size])

          if on_progress && total > 0
            pct = (io.pos / total * 100).floor.to_i
            if pct != last_pct
              on_progress.call(pct / 100.0)
              last_pct = pct
            end
          end
        end

        result
      end

      private def self.read_u16(io : IO::Memory) : UInt16
        bytes = read!(io, 2)
        (bytes[0].to_u16 << 8) | bytes[1]
      end

      private def self.read!(io : IO::Memory, count : Int32) : Bytes
        bytes = Bytes.new(count)
        n = io.read(bytes)
        raise Error.new("Truncated IPS patch (expected #{count} bytes, got #{n})") if n < count
        bytes
      end
    end

    # Applies a UPS (Universal Patching System) patch.
    #
    # File layout: "UPS1" magic, source_size + target_size varints, then
    # hunks until 12 bytes before the end; the footer is src_crc32 /
    # tgt_crc32 / patch_crc32, each 4 bytes little-endian.
    #
    # Each hunk: skip (varint - unchanged bytes to advance past), then
    # XOR data bytes terminated by 0x00 (which itself advances one byte).
    #
    # UPS varint (7-bit groups, LSB first, continuation bias):
    #   value = 0, shift = 0
    #   per byte: value += (b & 0x7f) << shift
    #             if bit7 set -> done; else shift += 7; value += 1 << shift
    module UPS
      # Returns the patched ROM (sized to the header's target_size).
      # Raises Error on a source or target CRC32 mismatch.
      def self.apply(rom : Bytes, patch : Bytes, on_progress : RomPatcher::Progress? = nil) : Bytes
        io = IO::Memory.new(patch, writable: false)
        io.skip(4) # "UPS1"

        read_varint(io) # source_size - not needed; target_size drives allocation
        target_size = RomPatcher.checked_size(read_varint(io), "UPS target size")

        result = Bytes.new(target_size)
        rom[0, Math.min(rom.size, target_size)].copy_to(result)

        pos = 0
        patch_end = patch.size - 12
        last_pct = -1

        while io.pos < patch_end
          if on_progress
            pct = (io.pos / patch_end.to_f * 100).floor.to_i
            if pct != last_pct
              on_progress.call(pct / 100.0)
              last_pct = pct
            end
          end

          pos += RomPatcher.checked_size(read_varint(io), "UPS hunk skip")

          while io.pos < patch_end
            byte = io.read_byte || raise Error.new("Truncated UPS patch")
            break if byte == 0x00
            result[pos] = result[pos] ^ byte if pos >= 0 && pos < result.size
            pos += 1
          end
          pos += 1 # advance past the matching byte at the hunk boundary
        end

        src_crc = RomPatcher.read_footer_crc(patch, 12)
        tgt_crc = RomPatcher.read_footer_crc(patch, 8)
        raise Error.new("UPS source CRC32 mismatch") unless Digest::CRC32.checksum(rom) == src_crc
        raise Error.new("UPS target CRC32 mismatch") unless Digest::CRC32.checksum(result) == tgt_crc

        result
      end

      protected def self.read_varint(io : IO::Memory) : Int64
        value = 0_i64
        shift = 0
        loop do
          byte = io.read_byte || raise Error.new("Truncated UPS patch (varint read past end)")
          value += (byte & 0x7f).to_i64 << shift
          break if (byte & 0x80) != 0
          shift += 7
          value += 1_i64 << shift
        end
        value
      end
    end

    # Applies a BPS (Beat Patch System) patch.
    #
    # File layout: "BPS1" magic, source_size + target_size +
    # metadata_size varints, <metadata_size> skipped bytes, then action
    # words until 12 bytes before the end; the footer is src_crc32 /
    # tgt_crc32 / patch_crc32, each 4 bytes little-endian.
    #
    # Each action word (varint): word = (length - 1) << 2 | mode
    #   mode 0  SourceRead - copy `length` source bytes at the current output offset
    #   mode 1  TargetRead - `length` literal bytes follow inline
    #   mode 2  SourceCopy - signed varint delta seeks the source cursor, then copy
    #   mode 3  TargetCopy - signed varint delta seeks the already-written target, then copy
    #           (byte-at-a-time on purpose: an overlapping forward copy is how
    #           BPS encodes runs)
    #
    # BPS varint (7-bit groups, additive shift - differs from UPS):
    #   value = 0, shift = 1
    #   per byte: value += (b & 0x7f) * shift
    #             if bit7 set -> done; else shift <<= 7; value += shift
    module BPS
      # Returns the patched ROM (sized to the header's target_size).
      # Raises Error on a source or target CRC32 mismatch.
      def self.apply(rom : Bytes, patch : Bytes, on_progress : RomPatcher::Progress? = nil) : Bytes
        raise Error.new("BPS patch too small to be valid") if patch.size < 16
        io = IO::Memory.new(patch, writable: false)
        io.skip(4) # "BPS1"

        read_varint(io) # source_size - not used; target_size drives allocation
        target_size = RomPatcher.checked_size(read_varint(io), "BPS target size")
        metadata_size = RomPatcher.checked_size(read_varint(io), "BPS metadata size")
        raise Error.new("Truncated BPS metadata") if io.pos + metadata_size > patch.size
        io.skip(metadata_size)

        target = Bytes.new(target_size)
        out_offset = 0
        src_offset = 0
        tgt_offset = 0
        patch_end = patch.size - 12
        last_pct = -1

        while io.pos < patch_end
          if on_progress
            pct = (io.pos / patch_end.to_f * 100).floor.to_i
            if pct != last_pct
              on_progress.call(pct / 100.0)
              last_pct = pct
            end
          end

          word = read_varint(io)
          mode = word & 3
          length = RomPatcher.checked_size((word >> 2) + 1, "BPS action length")

          case mode
          when 0 # SourceRead - copy from rom at current out position
            length.times do
              target[out_offset] = byte_at(rom, out_offset)
              out_offset += 1
            end
          when 1 # TargetRead - literal data
            slice = target[out_offset, length]
            raise Error.new("Truncated BPS patch") if io.read(slice) < length
            out_offset += length
          when 2 # SourceCopy - relative seek in source
            src_offset += checked_offset(read_signed_varint(io))
            length.times do
              target[out_offset] = byte_at(rom, src_offset)
              out_offset += 1
              src_offset += 1
            end
          else # TargetCopy - relative seek in target
            tgt_offset += checked_offset(read_signed_varint(io))
            length.times do
              target[out_offset] = byte_at(target, tgt_offset)
              out_offset += 1
              tgt_offset += 1
            end
          end
        end

        src_crc = RomPatcher.read_footer_crc(patch, 12)
        tgt_crc = RomPatcher.read_footer_crc(patch, 8)
        raise Error.new("BPS source CRC32 mismatch") unless Digest::CRC32.checksum(rom) == src_crc
        raise Error.new("BPS target CRC32 mismatch") unless Digest::CRC32.checksum(target) == tgt_crc

        target
      end

      # Out-of-range reads yield 0, like ruby's `getbyte(i) || 0` (with
      # the negative-index case pinned to 0 too, where ruby would wrap
      # from the end - only reachable from a malformed patch either way).
      private def self.byte_at(data : Bytes, index : Int32) : UInt8
        index >= 0 && index < data.size ? data[index] : 0_u8
      end

      protected def self.read_varint(io : IO::Memory) : Int64
        value = 0_i64
        shift = 1_i64
        loop do
          byte = io.read_byte || raise Error.new("Truncated BPS patch (varint read past end)")
          value += (byte & 0x7f).to_i64 * shift
          break if (byte & 0x80) != 0
          shift <<= 7
          value += shift
        end
        value
      end

      private def self.read_signed_varint(io : IO::Memory) : Int64
        value = read_varint(io)
        negative = (value & 1) != 0
        value >>= 1
        negative ? -value : value
      end

      private def self.checked_offset(delta : Int64) : Int32
        raise Error.new("BPS seek delta out of range") if delta > Int32::MAX || delta < Int32::MIN
        delta.to_i32
      end
    end

    # A varint-decoded size the decoders index Bytes with - anything
    # past Int32 can only come from a malformed patch.
    protected def self.checked_size(value : Int64, what : String) : Int32
      raise Error.new("#{what} out of range: #{value}") if value > Int32::MAX
      value.to_i32
    end

    # The two verification CRCs sit at 12 (source) and 8 (target) bytes
    # from the end, little-endian; the trailing 4 are the patch's own CRC.
    protected def self.read_footer_crc(patch : Bytes, from_end : Int32) : UInt32
      slice = patch[patch.size - from_end, 4]
      IO::ByteFormat::LittleEndian.decode(UInt32, slice)
    end
  end
end
