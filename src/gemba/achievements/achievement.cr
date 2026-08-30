require "json"

module Gemba
  module Achievements
    # One achievement as RetroAchievements defines it: the id/title/points
    # a list shows, plus the memaddr condition string rcheevos evaluates
    # and the Flags the site classifies it with. earned_at is nil until
    # the player has it - either pre-earned (r=unlocks said so) or
    # unlocked this session.
    record Achievement,
      id : UInt32,
      title : String,
      description : String,
      points : Int32,
      memaddr : String,
      flags : Int32,
      earned_at : Time? = nil do
      # RA's own Flags values: 3 is a published ("core") achievement, 5
      # one still in the unofficial set. Anything else (1 = local dev
      # work in progress) never reaches a player.
      CORE       = 3
      UNOFFICIAL = 5

      # RA injects site-wide system messages into PatchData.Achievements
      # with ids above this - not achievements, never activated.
      MAX_REAL_ID = 100_000_000_u32

      def earned? : Bool
        !@earned_at.nil?
      end

      def earn(at : Time = Time.utc) : Achievement
        copy_with(earned_at: at)
      end

      # Parses a PatchData.Achievements array, keeping only what should
      # actually be evaluated - ruby gemba's own filter: an empty
      # MemAddr has nothing to evaluate, only CORE (and UNOFFICIAL when
      # asked for) counts, and the system-message ids are skipped. An
      # entry missing/mistyped in a way that leaves no usable id or
      # memaddr is dropped rather than raising: one odd row in the
      # site's data should not take the whole game's list down.
      def self.from_patch(entries : JSON::Any?, include_unofficial : Bool) : Array(Achievement)
        list = entries.try(&.as_a?) || [] of JSON::Any
        list.compact_map { |entry| from_entry(entry, include_unofficial) }
      end

      private def self.from_entry(entry : JSON::Any, include_unofficial : Bool) : Achievement?
        id = integer(entry["ID"]?)
        memaddr = entry["MemAddr"]?.try(&.as_s?) || ""
        flags = (integer(entry["Flags"]?) || 0).to_i32
        return unless id && evaluable?(id, memaddr, flags, include_unofficial)

        new(id: id.to_u32,
          title: entry["Title"]?.try(&.as_s?) || "",
          description: entry["Description"]?.try(&.as_s?) || "",
          points: (integer(entry["Points"]?) || 0).to_i32,
          memaddr: memaddr,
          flags: flags)
      end

      private def self.evaluable?(id : Int64, memaddr : String, flags : Int32, include_unofficial : Bool) : Bool
        return false if id <= 0 || id > MAX_REAL_ID || memaddr.empty?

        flags == CORE || (flags == UNOFFICIAL && include_unofficial)
      end

      # RA's JSON is loose about numbers - ids and points arrive as
      # integers from the live site but as strings in some older
      # captures, and ruby's `.to_i` accepted both.
      protected def self.integer(value : JSON::Any?) : Int64?
        return unless value
        value.as_i64? || value.as_s?.try(&.to_i64?)
      end
    end
  end
end
