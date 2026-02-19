# frozen_string_literal: true

module Gemba
  # Manages SDL gamepad button → GBA bitmask mappings.
  #
  # Shares the same interface as {KeyboardMap} so that Player can
  # delegate to either without knowing which device type is active.
  class GamepadMap
    DEFAULT_MAP = {
      a:              KEY_A,
      b:              KEY_B,
      back:           KEY_SELECT,
      start:          KEY_START,
      dpad_up:        KEY_UP,
      dpad_down:      KEY_DOWN,
      dpad_left:      KEY_LEFT,
      dpad_right:     KEY_RIGHT,
      left_shoulder:  KEY_L,
      right_shoulder: KEY_R,
    }.freeze

    DEFAULT_DEAD_ZONE = 8000

    def initialize(config)
      @config = config
      @map = DEFAULT_MAP.dup
      @device = nil
      @dead_zone = DEFAULT_DEAD_ZONE
    end

    attr_accessor :device
    attr_reader :dead_zone

    def mask
      return 0 unless @device && !@device.closed?
      m = 0
      @map.each { |btn, bit| m |= bit if @device.button?(btn) }
      m
    end

    def set(gba_btn, gp_btn)
      bit = GBA_BTN_BITS[gba_btn] or return
      @map.delete_if { |_, v| v == bit }
      @map[gp_btn] = bit
    end

    def reset!
      @map = DEFAULT_MAP.dup
      @dead_zone = DEFAULT_DEAD_ZONE
    end

    def load_config
      return unless @device
      guid = @device.guid rescue return
      gp_cfg = @config.gamepad(guid, name: @device.name)

      @map = {}
      gp_cfg['mappings'].each do |gba_str, gp_str|
        bit = GBA_BTN_BITS[gba_str.to_sym]
        next unless bit
        @map[gp_str.to_sym] = bit
      end

      pct = gp_cfg['dead_zone']
      @dead_zone = (pct / 100.0 * 32767).round
    end

    def reload!
      @config.reload!
      load_config
    end

    def labels
      result = {}
      @map.each do |input, bit|
        gba_btn = GBA_BTN_BITS.key(bit)
        result[gba_btn] = input.to_s if gba_btn
      end
      result
    end

    def save_to_config
      return unless @device
      guid = @device.guid rescue return
      @config.gamepad(guid, name: @device.name)
      @config.set_dead_zone(guid, dead_zone_pct)
      @map.each do |gp_btn, bit|
        gba_btn = GBA_BTN_BITS.key(bit)
        @config.set_mapping(guid, gba_btn, gp_btn) if gba_btn
      end
    end

    def supports_deadzone? = true

    def dead_zone_pct
      (@dead_zone.to_f / 32767 * 100).round
    end

    def set_dead_zone(threshold)
      @dead_zone = threshold.to_i
    end
  end
end
