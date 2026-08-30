require "json"
require "./paths"

module Gemba
  # Persists settings to the SAME settings.json ruby gemba already
  # writes. Ruby's settings.json carries fields this port doesn't
  # understand yet (gamepad GUID maps, RA tokens, per-game overrides,
  # recent_roms...), so #save! keeps the whole parsed JSON::Any tree
  # and only replaces the specific "global" keys this class knows
  # about.
  #
  # Deliberately a small subset of ruby's own GLOBAL_DEFAULTS - only the
  # settings this port's VideoOutput/AudioOutput/EmulationWorker
  # actually have a knob for. Add a key here once the feature behind it
  # exists; a config key with nothing reading it is dead weight.
  class Config
    FILENAME = "settings.json"

    def self.path : String
      File.join(Paths.config_dir, FILENAME)
    end

    def initialize(@path : String = self.class.path)
      @data = File.exists?(@path) ? JSON.parse(File.read(@path)) : self.class.empty_tree
    end

    # Sentinel GUID keyboard bindings are stored under, alongside real
    # gamepad GUIDs - matches ruby gemba's own Config::KEYBOARD_GUID.
    KEYBOARD_GUID = "keyboard"

    DEFAULT_REWIND_SECONDS = 10

    def self.empty_tree : JSON::Any
      JSON.parse(%({"global": {}, "gamepads": {}, "hotkeys": {}, "recent_roms": []}))
    end

    def scale : Int32
      int("scale", 3)
    end

    def scale=(value : Int32) : Int32
      set("scale", value.clamp(1, 4).to_i64)
    end

    # Multiplier applied to a screenshot's native 240x160 GBA resolution
    # after Core writes it (see MainWindow#upscale_screenshot) - separate
    # from #scale, the WINDOW's zoom, since a screenshot has no window to
    # inherit a size from.
    def screenshot_scale : Int32
      int("screenshot_scale", 2)
    end

    def screenshot_scale=(value : Int32) : Int32
      set("screenshot_scale", value.clamp(1, 4).to_i64)
    end

    # 0-100, matching ruby's own on-disk percent representation.
    def volume : Int32
      int("volume", 100)
    end

    def volume=(pct : Int32) : Int32
      set("volume", pct.clamp(0, 100).to_i64)
    end

    def muted? : Bool
      bool("muted", false)
    end

    def muted=(value : Bool) : Bool
      set("muted", value)
    end

    def keep_aspect_ratio? : Bool
      bool("keep_aspect_ratio", true)
    end

    def keep_aspect_ratio=(value : Bool) : Bool
      set("keep_aspect_ratio", value)
    end

    # "nearest" or "linear".
    def pixel_filter : String
      str("pixel_filter", "nearest")
    end

    def pixel_filter=(value : String) : String
      set("pixel_filter", value)
    end

    def integer_scale? : Bool
      bool("integer_scale", false)
    end

    def integer_scale=(value : Bool) : Bool
      set("integer_scale", value)
    end

    def color_correction? : Bool
      bool("color_correction", false)
    end

    def color_correction=(value : Bool) : Bool
      set("color_correction", value)
    end

    def frame_blending? : Bool
      bool("frame_blending", false)
    end

    def frame_blending=(value : Bool) : Bool
      set("frame_blending", value)
    end

    # Pauses emulation whenever the app stops being the active one -
    # switching macOS Spaces, Cmd-Tab, clicking another window. Same key
    # and default as ruby gemba, which writes this file too.
    def pause_on_focus_loss? : Bool
      bool("pause_on_focus_loss", true)
    end

    def pause_on_focus_loss=(value : Bool) : Bool
      set("pause_on_focus_loss", value)
    end

    def show_fps? : Bool
      bool("show_fps", true)
    end

    def show_fps=(value : Bool) : Bool
      set("show_fps", value)
    end

    # Seconds of history EmulationWorker's rewind buffer keeps - only
    # takes effect for the NEXT ROM load, since mCoreRewindContext's
    # entry count is fixed for the life of the Core that owns it.
    def rewind_seconds : Int32
      int("rewind_seconds", DEFAULT_REWIND_SECONDS)
    end

    def rewind_seconds=(value : Int32) : Int32
      set("rewind_seconds", value.clamp(5, 30).to_i64)
    end

    # Zlib level for .grec video recordings (see Recorder) - 1 (the
    # default, fastest) through 9; ruby gemba's own key and clamp.
    def recording_compression : Int32
      int("recording_compression", 1)
    end

    def recording_compression=(value : Int32) : Int32
      set("recording_compression", value.clamp(1, 9).to_i64)
    end

    def ra_enabled? : Bool
      bool("ra_enabled", false)
    end

    def ra_enabled=(value : Bool) : Bool
      set("ra_enabled", value)
    end

    def ra_username : String
      str("ra_username", "")
    end

    def ra_username=(value : String) : String
      set("ra_username", value)
    end

    def ra_token : String
      str("ra_token", "")
    end

    def ra_token=(value : String) : String
      set("ra_token", value)
    end

    def ra_rich_presence? : Bool
      bool("ra_rich_presence", false)
    end

    def ra_rich_presence=(value : Bool) : Bool
      set("ra_rich_presence", value)
    end

    def ra_screenshot_on_unlock? : Bool
      bool("ra_screenshot_on_unlock", true)
    end

    def ra_screenshot_on_unlock=(value : Bool) : Bool
      set("ra_screenshot_on_unlock", value)
    end

    # Whether achievements still in RA's unofficial set (Flags 5) are
    # activated alongside the published ones. Same key ruby gemba
    # persists; no settings control yet - the achievements window is
    # where ruby exposes it.
    def ra_unofficial? : Bool
      bool("ra_unofficial", false)
    end

    def ra_unofficial=(value : Bool) : Bool
      set("ra_unofficial", value)
    end

    # "auto", or a two-letter code ("en", "ja").
    def locale : String
      str("locale", "auto")
    end

    def locale=(value : String) : String
      set("locale", value)
    end

    # "grid" (box-art cards) or "list" (sortable table) - which picker
    # view MainWindow shows. Matches ruby's own default.
    def picker_view : String
      str("picker_view", "grid")
    end

    def picker_view=(value : String) : String
      set("picker_view", value)
    end

    # 1-10, matching the 10-slot save-state picker.
    def quick_save_slot : Int32
      int("quick_save_slot", 1)
    end

    def quick_save_slot=(value : Int32) : Int32
      set("quick_save_slot", value.clamp(1, 10).to_i64)
    end

    def save_state_backup? : Bool
      bool("save_state_backup", true)
    end

    def save_state_backup=(value : Bool) : Bool
      set("save_state_backup", value)
    end

    # Seconds between accepted quick-saves - SaveStateManager's own
    # debounce window.
    def save_state_debounce : Float64
      float("save_state_debounce", 3.0)
    end

    def save_state_debounce=(value : Float64) : Float64
      value = value.clamp(0.0, 30.0)
      global["save_state_debounce"] = JSON::Any.new(value)
      value
    end

    # GBA button (e.g. "a", "select") -> input name for guid ("keyboard"
    # or an SDL gamepad GUID) - the same shape as ruby's
    # Config#mappings/#gamepad.
    def mappings(guid : String) : Hash(String, String)
      result = {} of String => String
      gamepad_entry(guid)["mappings"].as_h.each { |gba_btn, input| result[gba_btn] = input.as_s }
      result
    end

    # Rebinds gba_btn to input for guid, clearing any existing binding
    # that already used the same input so one input never maps to two.
    def set_mapping(guid : String, gba_btn : String, input : String) : Nil
      mappings = gamepad_entry(guid)["mappings"].as_h
      mappings.reject! { |_, v| v.as_s == input }
      mappings[gba_btn] = JSON::Any.new(input)
    end

    # Percentage (0-50) - 0 for the keyboard, which has no analog axes.
    def dead_zone(guid : String) : Int32
      gamepad_entry(guid)["dead_zone"].as_i
    end

    def set_dead_zone(guid : String, pct : Int32) : Nil
      gamepad_entry(guid)["dead_zone"] = JSON::Any.new(pct.clamp(0, 50).to_i64)
    end

    # Raw action -> hotkey tree (a hotkey is a String or an Array(String)
    # of modifiers + key) - kept as JSON::Any rather than HotkeyMap's own
    # Hotkey alias so this file doesn't need to require hotkey_map.cr.
    def hotkeys : Hash(String, JSON::Any)
      hotkeys_hash
    end

    def set_hotkey(action : String, hotkey : String | Array(String)) : Nil
      json = hotkey.is_a?(Array) ? JSON::Any.new(hotkey.map { |part| JSON::Any.new(part) }) : JSON::Any.new(hotkey)
      hotkeys_hash[action] = json
    end

    def save! : Nil
      dir = File.dirname(@path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(@path, @data.to_json)
    end

    # Re-reads @data from disk, discarding any unsaved in-memory changes
    # - for a caller (e.g. HotkeyMap#reload!) that wants the latest
    # on-disk state before rebinding.
    def reload! : Nil
      @data = File.exists?(@path) ? JSON.parse(File.read(@path)) : self.class.empty_tree
    end

    private def global : Hash(String, JSON::Any)
      h = @data.as_h
      h["global"] = JSON::Any.new({} of String => JSON::Any) unless h["global"]?
      h["global"].as_h
    end

    private def gamepads : Hash(String, JSON::Any)
      h = @data.as_h
      h["gamepads"] = JSON::Any.new({} of String => JSON::Any) unless h["gamepads"]?
      h["gamepads"].as_h
    end

    private def hotkeys_hash : Hash(String, JSON::Any)
      h = @data.as_h
      h["hotkeys"] = JSON::Any.new({} of String => JSON::Any) unless h["hotkeys"]?
      h["hotkeys"].as_h
    end

    private def gamepad_entry(guid : String) : Hash(String, JSON::Any)
      gp = gamepads
      unless gp[guid]?
        default_dead_zone = guid == KEYBOARD_GUID ? 0 : 25
        gp[guid] = JSON::Any.new({
          "dead_zone" => JSON::Any.new(default_dead_zone.to_i64),
          "mappings"  => JSON::Any.new({} of String => JSON::Any),
        })
      end
      gp[guid].as_h
    end

    private def int(key : String, default : Int32) : Int32
      global[key]?.try(&.as_i) || default
    end

    private def bool(key : String, default : Bool) : Bool
      value = global[key]?
      value.nil? ? default : value.as_bool
    end

    private def str(key : String, default : String) : String
      global[key]?.try(&.as_s) || default
    end

    # Handles a value written as either a whole number (`3`) or a
    # decimal (`3.0`) - JSON::Any#as_f raises on the former.
    private def float(key : String, default : Float64) : Float64
      value = global[key]?
      return default unless value
      value.as_f? || value.as_i?.try(&.to_f64) || default
    end

    private def set(key : String, value : Int64) : Int32
      global[key] = JSON::Any.new(value)
      value.to_i
    end

    private def set(key : String, value : Bool) : Bool
      global[key] = JSON::Any.new(value)
      value
    end

    private def set(key : String, value : String) : String
      global[key] = JSON::Any.new(value)
      value
    end
  end
end
