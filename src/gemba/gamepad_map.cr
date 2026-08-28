require "./button"
require "tryst-sdl"
require "./config"

module Gemba
  # SDL gamepad button -> GBA Button mapping. Shares the same #mask/
  # #set/#reset!/#labels shape as KeyboardMap.
  class GamepadMap
    DEFAULT_MAP = {
      :a              => Button::A,
      :b              => Button::B,
      :back           => Button::Select,
      :start          => Button::Start,
      :dpad_up        => Button::Up,
      :dpad_down      => Button::Down,
      :dpad_left      => Button::Left,
      :dpad_right     => Button::Right,
      :left_shoulder  => Button::L,
      :right_shoulder => Button::R,
    }

    # Matches Tryst::SDL::Gamepad::DEAD_ZONE - not applied to any axis
    # directly, since the default map above is digital d-pad buttons
    # only.
    DEFAULT_DEAD_ZONE = 8000

    property device : Tryst::SDL::Gamepad?
    getter dead_zone : Int32

    @map : Hash(Symbol, Button)

    def initialize
      @map = DEFAULT_MAP.dup
      @dead_zone = DEFAULT_DEAD_ZONE
    end

    def mask : Button
      device = @device
      return Button::None unless device

      held = Button::None
      @map.each { |gp_button, button| held |= button if device.button?(gp_button) }
      held
    end

    def set(gba_btn : Button, gp_button : Symbol) : Nil
      @map.reject! { |_, v| v == gba_btn }
      @map[gp_button] = gba_btn
    end

    # Same as #set(Button, Symbol), for a caller (the settings UI) that
    # only has the button's name as a String - a name BUTTON_VALUES
    # doesn't recognize is silently ignored, matching #load_config's own
    # handling of an unrecognized saved name.
    def set(gba_btn : Button, gp_button : String) : Nil
      symbol = Tryst::SDL::Gamepad::BUTTON_VALUES.keys.find { |k| k.to_s == gp_button }
      set(gba_btn, symbol) if symbol
    end

    def reset! : Nil
      @map = DEFAULT_MAP.dup
      @dead_zone = DEFAULT_DEAD_ZONE
    end

    # Loads bindings + dead zone for the current #device's own GUID -
    # a no-op with no device attached, since a gamepad's config is
    # keyed by its GUID.
    def load_config(config : Config) : Nil
      device = @device
      return unless device

      saved = config.mappings(device.guid)
      if saved.empty?
        @map = DEFAULT_MAP.dup
      else
        map = {} of Symbol => Button
        saved.each do |gba_str, gp_str|
          button = Button.parse?(gba_str)
          gp_button = Tryst::SDL::Gamepad::BUTTON_VALUES.keys.find { |k| k.to_s == gp_str }
          map[gp_button] = button if button && gp_button
        end
        @map = map
      end

      @dead_zone = (config.dead_zone(device.guid) / 100.0 * 32767).round.to_i
    end

    def save_to_config(config : Config) : Nil
      device = @device
      return unless device

      config.set_dead_zone(device.guid, dead_zone_pct)
      @map.each { |gp_button, button| config.set_mapping(device.guid, button.to_s.downcase, gp_button.to_s) }
    end

    def reload!(config : Config) : Nil
      config.reload!
      load_config(config)
    end

    def labels : Hash(Button, Symbol)
      result = {} of Button => Symbol
      @map.each { |gp_button, button| result[button] = gp_button }
      result
    end

    def supports_deadzone? : Bool
      true
    end

    def dead_zone_pct : Int32
      (@dead_zone.to_f / 32767 * 100).round.to_i
    end

    def dead_zone=(threshold : Int32) : Int32
      @dead_zone = threshold
    end
  end
end
