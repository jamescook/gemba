# frozen_string_literal: true

require 'fileutils'

module Gemba
  # Applies IPS, BPS, or UPS patch files to GBA ROM files.
  #
  # Format support:
  #   IPS  — simplest; no checksums; RLE support
  #   BPS  — Beat Patch System; delta encoding with CRC32 verification
  #   UPS  — Universal Patching System; XOR hunks with CRC32 verification
  #
  # Usage:
  #   RomPatcher.patch(rom_path: "game.gba", patch_path: "fix.ips", out_path: "patched.gba")
  #   # or invoke a format class directly:
  #   RomPatcher::IPS.apply(rom_bytes, patch_bytes)  # => patched_bytes
  #
  class RomPatcher
    CHUNK = 256 * 1024 # 256 KB

    # Auto-detect format, apply patch, write output file.
    #
    # Progress budget:
    #   0–15%   read ROM
    #   15–25%  read patch
    #   25–90%  format apply (IPS/BPS/UPS)
    #   90–100% write output
    #
    # @param rom_path   [String] source ROM (read-only)
    # @param patch_path [String] patch file (.ips / .bps / .ups)
    # @param out_path   [String] where to write the result
    # @param on_progress [Proc, nil] called with a Float (0.0..1.0)
    # @return [String] out_path
    # @raise [RuntimeError] on unknown format or checksum failure
    def self.patch(rom_path:, patch_path:, out_path:, on_progress: nil)
      rom   = read_chunked(rom_path,   0.0, 0.15, on_progress)
      patch = read_chunked(patch_path, 0.15, 0.25, on_progress)

      klass = case detect_format(patch)
              when :ips then IPS
              when :bps then BPS
              when :ups then UPS
              else raise "Unknown patch format (expected IPS/BPS/UPS magic)"
              end

      apply_cb = on_progress && ->(pct) { on_progress.call(0.25 + pct * 0.65) }
      result = klass.apply(rom, patch, on_progress: apply_cb)
      on_progress&.call(0.90)

      FileUtils.mkdir_p(File.dirname(out_path))
      write_chunked(out_path, result, 0.90, 1.0, on_progress)
      on_progress&.call(1.0)
      out_path
    end

    # @return [:ips, :bps, :ups, nil]
    def self.detect_format(patch_data)
      return :ips if patch_data.start_with?("PATCH")
      return :bps if patch_data.start_with?("BPS1")
      return :ups if patch_data.start_with?("UPS1")
      nil
    end

    # Return a path that does not collide with existing files.
    # If +path+ exists, appends -(2), -(3), ... before the extension.
    def self.safe_out_path(path)
      return path unless File.exist?(path)
      ext  = File.extname(path)
      base = path.chomp(ext)
      n = 2
      loop do
        candidate = "#{base}-(#{n})#{ext}"
        return candidate unless File.exist?(candidate)
        n += 1
      end
    end

    # Read a file in chunks, reporting progress from +pct_start+ to +pct_end+.
    def self.read_chunked(path, pct_start, pct_end, on_progress)
      size = File.size(path).to_f
      buf  = String.new(encoding: 'BINARY')
      read = 0
      File.open(path, 'rb') do |f|
        while (chunk = f.read(CHUNK))
          buf  << chunk
          read += chunk.bytesize
          on_progress&.call(pct_start + (read / size) * (pct_end - pct_start))
        end
      end
      buf
    end
    private_class_method :read_chunked

    # Write a string to a file in chunks, reporting progress from +pct_start+ to +pct_end+.
    def self.write_chunked(path, data, pct_start, pct_end, on_progress)
      size    = data.bytesize.to_f
      written = 0
      File.open(path, 'wb') do |f|
        while written < data.bytesize
          n = [CHUNK, data.bytesize - written].min
          f.write(data.byteslice(written, n))
          written += n
          on_progress&.call(pct_start + (written / size) * (pct_end - pct_start))
        end
      end
    end
    private_class_method :write_chunked
  end
end
