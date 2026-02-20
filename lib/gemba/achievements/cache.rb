# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module Gemba
  module Achievements
    # Persistent per-ROM achievement cache.
    #
    # Stores the full achievement list (definitions + earned status) for each
    # ROM as a JSON file under Config.achievements_cache_dir/<rom_id>.json.
    # Written after every successful sync; read on demand by the window when
    # a game is selected that isn't currently loaded in the emulator.
    #
    # Format:
    #   { "synced_at": "<iso8601>",
    #     "achievements": [ { "id":, "title":, "description":, "points":,
    #                         "earned_at": "<iso8601>|null" }, … ] }
    module Cache
      def self.write(rom_id, achievements)
        path = cache_path(rom_id)
        FileUtils.mkdir_p(File.dirname(path))
        data = {
          'synced_at'    => Time.now.utc.iso8601,
          'achievements' => achievements.map { |a|
            {
              'id'          => a.id,
              'title'       => a.title,
              'description' => a.description,
              'points'      => a.points,
              'earned_at'   => a.earned_at&.utc&.iso8601,
            }
          },
        }
        File.write(path, JSON.generate(data))
        Gemba.log(:info) { "Achievements cache written: #{rom_id} (#{achievements.size} achievements)" }
      rescue => e
        Gemba.log(:warn) { "Achievements cache write failed for #{rom_id}: #{e.message}" }
      end

      # @return [Array<Achievement>, nil] cached list, or nil if no cache exists
      def self.read(rom_id)
        path = cache_path(rom_id)
        return nil unless File.exist?(path)

        data = JSON.parse(File.read(path))
        list = (data['achievements'] || []).map do |a|
          Achievement.new(
            id:          a['id'].to_s,
            title:       a['title'].to_s,
            description: a['description'].to_s,
            points:      a['points'].to_i,
            earned_at:   a['earned_at'] ? Time.iso8601(a['earned_at']) : nil,
          )
        end
        Gemba.log(:info) { "Achievements cache read: #{rom_id} (#{list.size} achievements, synced #{data['synced_at']})" }
        list
      rescue => e
        Gemba.log(:warn) { "Achievements cache read failed for #{rom_id}: #{e.message}" }
        nil
      end

      def self.cache_path(rom_id)
        File.join(Config.achievements_cache_dir, "#{rom_id}.json")
      end
      private_class_method :cache_path
    end
  end
end
