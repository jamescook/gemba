# frozen_string_literal: true

module Gemba
  # Immutable value object representing a GBA BIOS file.
  # The stored config value is just the filename; this object resolves
  # it to a full path and computes metadata on demand (memoized).
  class Bios
    EXPECTED_SIZE = 16_384

    attr_reader :path

    def initialize(path:)
      @path = path
    end

    # Build a Bios from a bare filename stored in config.
    def self.from_config_name(name)
      return nil if name.nil? || name.empty?
      new(path: File.join(Config.bios_dir, name))
    end

    def filename = File.basename(@path)
    def exists?  = File.exist?(@path)

    def size
      @size ||= exists? ? File.size(@path) : 0
    end

    def valid?
      exists? && size == EXPECTED_SIZE
    end

    def checksum
      return @checksum if defined?(@checksum)
      @checksum = valid? ? Gemba.gba_bios_checksum(File.binread(@path)) : nil
    end

    def official? = checksum == GBA_BIOS_CHECKSUM
    def ds_mode?  = checksum == GBA_DS_BIOS_CHECKSUM
    def known?    = official? || ds_mode?

    def label
      return "Official GBA BIOS"  if official?
      return "NDS GBA Mode BIOS"  if ds_mode?
      "Unknown BIOS"
    end

    def status_text
      return "File not found (#{@path})" unless exists?
      return "Invalid size (#{size} bytes, expected #{EXPECTED_SIZE})" unless valid?
      "#{label} · #{size} bytes"
    end
  end
end
