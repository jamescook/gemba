require "./config"

module Gemba
  # Maps player actions (quit, pause, etc.) to keyboard hotkeys. A
  # hotkey is either a plain keysym String ("F5") or a modifier-prefixed
  # Array (["Control", "s"]).
  class HotkeyMap
    alias Hotkey = String | Array(String)

    ACTIONS = %i[quit pause fast_forward fullscreen show_fps
      quick_save quick_load save_states screenshot rewind
      record input_record open_rom]

    DEFAULTS = {
      :quit         => "q",
      :pause        => "p",
      :fast_forward => "Tab",
      :fullscreen   => "F11",
      :show_fps     => "F3",
      :quick_save   => "F5",
      :quick_load   => "F8",
      :save_states  => "F6",
      :screenshot   => "F9",
      :rewind       => ["Shift", "Tab"],
      :record       => "F10",
      :input_record => "F4",
      :open_rom     => ["Control", "o"],
    } of Symbol => Hotkey

    # Tk keysyms that are modifier keys -> normalized name.
    MODIFIER_KEYSYMS = {
      "Control_L" => "Control", "Control_R" => "Control",
      "Shift_L" => "Shift", "Shift_R" => "Shift",
      "Alt_L" => "Alt", "Alt_R" => "Alt",
      "Meta_L" => "Alt", "Meta_R" => "Alt",
      "Super_L" => "Super", "Super_R" => "Super",
    }

    # Tk event state bitmask -> modifier name.
    STATE_BITS = {1 => "Shift", 4 => "Control", 8 => "Alt"}

    # Display-friendly modifier names.
    MODIFIER_DISPLAY = {"Control" => "Ctrl", "Shift" => "Shift", "Alt" => "Alt", "Super" => "Super"}

    # Canonical sort order for modifiers.
    MODIFIER_ORDER = %w[Control Shift Alt Super]

    # Tk keysym aliases - modifier combos can produce variant keysyms
    # that must be normalized for both lookup and capture.
    #
    # Known cases:
    #   Shift+Tab   -> ISO_Left_Tab
    #   Shift+1     -> exclam (US layout)
    #   Shift+a     -> A (universal - handled dynamically in #normalize_keysym)
    KEYSYM_ALIASES = {
      "ISO_Left_Tab" => "Tab",
      # Shift+number (US keyboard layout)
      "exclam" => "1", "at" => "2", "numbersign" => "3",
      "dollar" => "4", "percent" => "5", "asciicircum" => "6",
      "ampersand" => "7", "asterisk" => "8", "parenleft" => "9",
      "parenright" => "0",
      # Shift+punctuation (US keyboard layout)
      "underscore" => "minus", "plus" => "equal",
      "braceleft" => "bracketleft", "braceright" => "bracketright",
      "bar" => "backslash", "colon" => "semicolon",
      "quotedbl" => "apostrophe", "less" => "comma",
      "greater" => "period", "question" => "slash",
      "asciitilde" => "grave",
    }

    @map : Hash(Symbol, Hotkey)

    def initialize
      @map = DEFAULTS.dup
    end

    def key_for(action : Symbol) : Hotkey?
      @map[action]?
    end

    # Looks up which action matches a keysym + active modifiers.
    def action_for(keysym : String, modifiers : Set(String)? = nil) : Symbol?
      normalized = self.class.normalize_keysym(keysym)
      mods = modifiers && !modifiers.empty? ? modifiers : nil

      @map.each do |action, hotkey|
        if hotkey.is_a?(Array)
          hotkey_mods = hotkey[0...-1]
          hotkey_key = hotkey.last
          next unless mods && hotkey_key == normalized
          next unless hotkey_mods.size == mods.size && hotkey_mods.all? { |modifier| mods.includes?(modifier) }
          return action
        else
          return action if hotkey == normalized && mods.nil?
        end
      end
      nil
    end

    # Rebinds action to a new hotkey, clearing any existing action
    # bound to the same hotkey to prevent conflicts.
    def set(action : Symbol, hotkey : Hotkey) : Nil
      normalized = self.class.normalize(hotkey)
      @map.reject! { |_, v| self.class.normalize(v) == normalized }
      @map[action] = normalized
    end

    def reset! : Nil
      @map = DEFAULTS.dup
    end

    # Loads hotkeys from config, falling back to defaults for any
    # action config has nothing saved for.
    def load_config(config : Config) : Nil
      saved = config.hotkeys
      return if saved.empty?

      map = DEFAULTS.dup
      saved.each do |action_str, json|
        action = ACTIONS.find { |a| a.to_s == action_str }
        next unless action
        hotkey = json.as_a? ? json.as_a.map(&.as_s) : json.as_s
        map[action] = self.class.normalize(hotkey)
      end
      @map = map
    end

    # Writes current hotkeys to config (does not call config.save!).
    def save_to_config(config : Config) : Nil
      @map.each { |action, hotkey| config.set_hotkey(action.to_s, hotkey) }
    end

    def reload!(config : Config) : Nil
      config.reload!
      load_config(config)
    end

    def labels : Hash(Symbol, Hotkey)
      @map.dup
    end

    # Sorts an Array hotkey's modifiers into canonical order. A plain
    # String hotkey (no modifiers) passes through unchanged.
    def self.normalize(hotkey : Hotkey) : Hotkey
      return hotkey unless hotkey.is_a?(Array)
      return hotkey.last if hotkey.size == 1

      key = hotkey.last
      mods = hotkey[0...-1].sort_by { |modifier| MODIFIER_ORDER.index(modifier) || 99 }
      mods + [key]
    end

    # Human-readable display name for a hotkey, e.g. "F5" or "Ctrl+S".
    def self.display_name(hotkey : Hotkey) : String
      return hotkey unless hotkey.is_a?(Array)

      parts = hotkey[0...-1].map { |modifier| MODIFIER_DISPLAY[modifier]? || modifier }
      parts << hotkey.last.capitalize
      parts.join("+")
    end

    # Normalizes variant Tk keysyms to their canonical form. Handles:
    # ISO_Left_Tab -> Tab, Shift+letter uppercase -> lowercase,
    # Shift+number -> number (US layout), Shift+punctuation -> base key.
    def self.normalize_keysym(keysym : String) : String
      return KEYSYM_ALIASES[keysym] if KEYSYM_ALIASES.has_key?(keysym)
      return keysym.downcase if keysym.size == 1 && keysym.matches?(/\A[A-Z]\z/)
      keysym
    end

    def self.modifier_key?(keysym : String) : Bool
      MODIFIER_KEYSYMS.has_key?(keysym)
    end

    # Normalizes a Tk modifier keysym (e.g. "Control_L" -> "Control").
    def self.normalize_modifier(keysym : String) : String?
      MODIFIER_KEYSYMS[keysym]?
    end

    # Extracts active modifier names from a Tk event state bitmask.
    def self.modifiers_from_state(state : Int32) : Set(String)
      result = Set(String).new
      STATE_BITS.each { |bit, name| result << name if (state & bit) != 0 }
      result
    end
  end
end
