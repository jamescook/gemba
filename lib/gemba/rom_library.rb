# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module Gemba
  # Persistent catalog of known ROMs.
  #
  # Stored as JSON at Config.config_dir/rom_library.json. Each entry records
  # the ROM's path, title, game code, rom_id, platform, and timestamps.
  # The library is loaded once on boot and updated whenever a ROM is loaded.
  class RomLibrary
    FILENAME = 'rom_library.json'

    def initialize(path = self.class.default_path, subscribe: true)
      @path = path
      @roms = []
      load!
      subscribe_to_bus if subscribe
    end

    def self.default_path
      File.join(Config.config_dir, FILENAME)
    end

    # All known ROMs, sorted by last_played descending (most recent first).
    # @return [Array<Hash>]
    def all
      @roms.sort_by { |r| r['last_played'] || r['added_at'] || '' }.reverse
    end

    # Add or update a ROM entry. Upserts by rom_id.
    # @param attrs [Hash] must include 'rom_id'; other keys merged in
    def add(attrs)
      rom_id = attrs['rom_id'] || attrs[:rom_id]
      raise ArgumentError, 'rom_id is required' unless rom_id

      attrs = stringify_keys(attrs)
      existing = @roms.find { |r| r['rom_id'] == rom_id }
      if existing
        existing.merge!(attrs)
      else
        attrs['added_at'] ||= Time.now.utc.iso8601
        @roms << attrs
      end
    end

    # Remove a ROM entry by rom_id.
    def remove(rom_id)
      @roms.reject! { |r| r['rom_id'] == rom_id }
    end

    # Update last_played timestamp for a ROM.
    def touch(rom_id)
      entry = find(rom_id)
      entry['last_played'] = Time.now.utc.iso8601 if entry
    end

    # Find a ROM entry by rom_id.
    # @return [Hash, nil]
    def find(rom_id)
      @roms.find { |r| r['rom_id'] == rom_id }
    end

    # @return [Integer]
    def size
      @roms.size
    end

    # Persist to disk.
    def save!
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate({ 'roms' => @roms }))
    end

    private

    def subscribe_to_bus
      Gemba.bus.on(:rom_loaded) do |rom_id:, path:, title:, game_code:, platform:, **|
        add(
          'rom_id'    => rom_id,
          'path'      => path,
          'title'     => title,
          'game_code' => game_code,
          'platform'  => platform.downcase,
        )
        touch(rom_id)
        save!
      end
    end

    def load!
      return unless File.exist?(@path)
      data = JSON.parse(File.read(@path))
      @roms = data['roms'] || []
    rescue JSON::ParserError
      @roms = []
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end
  end
end
