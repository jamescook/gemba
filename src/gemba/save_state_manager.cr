require "./core"
require "./paths"
require "./rom_library"

module Gemba
  # Save/load-state persistence: per-ROM state directory, backup
  # rotation, and debounce. Runs entirely on the worker thread alongside
  # Core; Core is worker-thread-only, so don't touch this from the main
  # thread. Config is passed as plain constructor args (Config itself
  # isn't thread-safe).
  class SaveStateManager
    DEFAULT_QUICK_SAVE_SLOT = 1
    DEFAULT_BACKUP          = true
    DEFAULT_DEBOUNCE        = 3.seconds

    property quick_save_slot : Int32
    property? backup : Bool
    property debounce : Time::Span
    getter state_dir : String

    @last_save_at : Time::Instant?

    # state_dir overrides the computed states/<game>-<crc>/ path -
    # production code omits it; a spec passes an isolated tempdir so it
    # never touches a real user's actual save states.
    def initialize(core : Core, state_dir : String? = nil,
                   @quick_save_slot : Int32 = DEFAULT_QUICK_SAVE_SLOT,
                   @backup : Bool = DEFAULT_BACKUP,
                   @debounce : Time::Span = DEFAULT_DEBOUNCE)
      @last_save_at = nil
      @state_dir = state_dir || SaveStateManager.state_dir_for(core)
    end

    # e.g. states/AGB-BTKE-A1B2C3D4/ - same naming ruby gemba uses, so
    # existing save states are found rather than orphaned.
    def self.state_dir_for(core : Core) : String
      state_dir_for(core.game_code, core.checksum)
    end

    # RomLibrary.rom_id is a pure function (no I/O, no shared state), so
    # this lets main-thread callers compute the path without Core.
    def self.state_dir_for(game_code : String, checksum : UInt32) : String
      File.join(Paths.states_dir, RomLibrary.rom_id(game_code, checksum))
    end

    def self.state_path(state_dir : String, slot : Int32) : String
      File.join(state_dir, "state#{slot}.ss")
    end

    # The per-slot thumbnail PNG's path - written by the main thread
    # (VideoOutput#last_frame_argb, see MainWindow) once a save succeeds,
    # not by this class - see the class comment on why.
    def self.screenshot_path(state_dir : String, slot : Int32) : String
      File.join(state_dir, "state#{slot}.png")
    end

    def state_path(slot : Int32) : String
      self.class.state_path(@state_dir, slot)
    end

    # Returns {success, message} - message is meant for a toast/status
    # line, always present on failure, only sometimes on success (a
    # debounced save has nothing worth telling the user).
    def save_state(core : Core, slot : Int32) : {Bool, String}
      return {false, "no ROM loaded"} if core.destroyed?

      now = Time.instant
      last_save_at = @last_save_at
      if last_save_at && now.duration_since(last_save_at) < @debounce
        return {false, "saved too recently, try again in a moment"}
      end

      Dir.mkdir_p(@state_dir) unless Dir.exists?(@state_dir)
      ss = state_path(slot)
      File.rename(ss, "#{ss}.bak") if backup? && File.exists?(ss)

      if core.save_state_to_file(ss)
        @last_save_at = now
        {true, "saved to slot #{slot}"}
      else
        {false, "failed to save state"}
      end
    end

    def load_state(core : Core, slot : Int32) : {Bool, String}
      return {false, "no ROM loaded"} if core.destroyed?

      ss = state_path(slot)
      return {false, "no save in slot #{slot}"} unless File.exists?(ss)

      if core.load_state_from_file(ss)
        {true, "loaded slot #{slot}"}
      else
        {false, "failed to load state"}
      end
    end

    def quick_save(core : Core) : {Bool, String}
      save_state(core, @quick_save_slot)
    end

    def quick_load(core : Core) : {Bool, String}
      load_state(core, @quick_save_slot)
    end
  end
end
