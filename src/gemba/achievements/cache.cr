require "json"
require "../session_logger"
require "./achievement"

module Gemba
  module Achievements
    # Persistent per-ROM achievement cache: the full list (definitions
    # plus earned state) for each game as a JSON file, dir/<rom_id>.json,
    # written after every successful load/sync/unlock and read back when
    # the achievements window shows a game that isn't the loaded one.
    #
    # The same directory and file shape ruby gemba writes
    # (<config_dir>/achievements/<rom_id>.json, synced_at + achievements
    # with id/title/description/points/earned_at), so caches the two
    # already share on disk load here too - this port adds memaddr and
    # flags so a round trip reproduces the record exactly, and reads a
    # file missing them as an empty memaddr / zero flags.
    #
    # Plain blocking file I/O, no thread awareness: the caller routes it
    # through App#off_thread like every other file access in this app.
    # dir is always an explicit argument (Paths.achievements_cache_dir in
    # production), so a spec can point it at a tempdir.
    module Cache
      def self.path(rom_id : String, dir : String) : String
        File.join(dir, "#{rom_id}.json")
      end

      # A failure is logged, never raised - losing a cache write is not
      # worth interrupting play over.
      def self.write(rom_id : String, achievements : Array(Achievement), dir : String) : Nil
        Dir.mkdir_p(dir)
        data = {
          "synced_at"    => Time.utc.to_rfc3339,
          "achievements" => achievements.map do |achievement|
            {
              "id"          => achievement.id,
              "title"       => achievement.title,
              "description" => achievement.description,
              "points"      => achievement.points,
              "memaddr"     => achievement.memaddr,
              "flags"       => achievement.flags,
              "earned_at"   => achievement.earned_at.try(&.to_utc.to_rfc3339),
            }
          end,
        }
        File.write(path(rom_id, dir), data.to_json)
        Gemba.log { "Achievements cache written: #{rom_id} (#{achievements.size} achievements)" }
      rescue ex
        Gemba.log(SessionLogger::Level::Warn) { "Achievements cache write failed for #{rom_id}: #{ex.message}" }
      end

      # The cached list, or nil when there is no cache for rom_id yet
      # (or the file can't be read - logged, and treated the same).
      def self.read(rom_id : String, dir : String) : Array(Achievement)?
        file = path(rom_id, dir)
        return unless File.exists?(file)

        data = JSON.parse(File.read(file))
        entries = data["achievements"]?.try(&.as_a?) || [] of JSON::Any
        list = entries.map do |entry|
          earned_at = entry["earned_at"]?.try(&.as_s?)
          Achievement.new(
            id: (Achievement.integer(entry["id"]?) || 0).to_u32,
            title: entry["title"]?.try(&.as_s?) || "",
            description: entry["description"]?.try(&.as_s?) || "",
            points: (Achievement.integer(entry["points"]?) || 0).to_i32,
            memaddr: entry["memaddr"]?.try(&.as_s?) || "",
            flags: (Achievement.integer(entry["flags"]?) || 0).to_i32,
            earned_at: earned_at ? Time.parse_rfc3339(earned_at) : nil)
        end
        Gemba.log { "Achievements cache read: #{rom_id} (#{list.size} achievements, synced #{data["synced_at"]?})" }
        list
      rescue ex
        Gemba.log(SessionLogger::Level::Warn) { "Achievements cache read failed for #{rom_id}: #{ex.message}" }
        nil
      end
    end
  end
end
