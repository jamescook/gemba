# frozen_string_literal: true

module Gemba
  # Manages keyboard keysym → GBA bitmask mappings.
  #
  # Shares the same interface as {GamepadMap} so that Player can
  # delegate to either without knowing which device type is active.
  class KeyboardMap
    DEFAULT_MAP = {
      'z'         => KEY_A,
      'x'         => KEY_B,
      'BackSpace' => KEY_SELECT,
      'Return'    => KEY_START,
      'Right'     => KEY_RIGHT,
      'Left'      => KEY_LEFT,
      'Up'        => KEY_UP,
      'Down'      => KEY_DOWN,
      'a'         => KEY_L,
      's'         => KEY_R,
    }.freeze

    def initialize(config)
      @config = config
      @map = DEFAULT_MAP.dup
      @device = nil
      load_config
    end

    attr_writer :device

    def mask
      return 0 unless @device
      m = 0
      @map.each { |key, bit| m |= bit if @device.button?(key) }
      m
    end

    def set(gba_btn, input_key)
      bit = GBA_BTN_BITS[gba_btn] or return
      @map.delete_if { |_, v| v == bit }
      @map[input_key.to_s] = bit
    end

    def reset!
      @map = DEFAULT_MAP.dup
    end

    def load_config
      cfg = @config.mappings(Config::KEYBOARD_GUID)
      if cfg.empty?
        @map = DEFAULT_MAP.dup
      else
        @map = {}
        cfg.each do |gba_str, keysym|
          bit = GBA_BTN_BITS[gba_str.to_sym]
          next unless bit
          @map[keysym] = bit
        end
      end
    end

    def reload!
      @config.reload!
      load_config
    end

    def labels
      result = {}
      @map.each do |input, bit|
        gba_btn = GBA_BTN_BITS.key(bit)
        result[gba_btn] = input if gba_btn
      end
      result
    end

    def save_to_config
      @map.each do |input, bit|
        gba_btn = GBA_BTN_BITS.key(bit)
        @config.set_mapping(Config::KEYBOARD_GUID, gba_btn, input) if gba_btn
      end
    end

    def supports_deadzone? = false
    def dead_zone_pct = 0

    def set_dead_zone(_)
      raise NotImplementedError, "keyboard does not support dead zones"
    end
  end
end
