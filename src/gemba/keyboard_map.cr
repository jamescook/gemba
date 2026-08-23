require "./button"
require "./key_source"
require "./config"

module Gemba
  # Keysym -> GBA Button mapping. Shares the same #mask/#set/#reset!/
  # #labels shape as GamepadMap so a caller can hold either without
  # knowing which device type is active.
  class KeyboardMap
    DEFAULT_MAP = {
      "z"         => Button::A,
      "x"         => Button::B,
      "BackSpace" => Button::Select,
      "Return"    => Button::Start,
      "Right"     => Button::Right,
      "Left"      => Button::Left,
      "Up"        => Button::Up,
      "Down"      => Button::Down,
      "a"         => Button::L,
      "s"         => Button::R,
    }

    # KeySource rather than VirtualKeyboard specifically - a real
    # MainWindow hands this a Tryst::SDL::Viewport adapter instead, see
    # KeySource's own doc comment.
    property device : KeySource?

    @map : Hash(String, Button)

    def initialize
      @map = DEFAULT_MAP.dup
    end

    def mask : Button
      device = @device
      return Button::None unless device

      held = Button::None
      @map.each { |key, button| held |= button if device.button?(key) }
      held
    end

    # Rebinds gba_btn to input_key, clearing any existing binding that
    # already used the same button so one input never maps to two.
    def set(gba_btn : Button, input_key : String) : Nil
      @map.reject! { |_, v| v == gba_btn }
      @map[input_key] = gba_btn
    end

    def reset! : Nil
      @map = DEFAULT_MAP.dup
    end

    # Loads bindings from config, falling back to defaults if it has
    # none saved yet.
    def load_config(config : Config) : Nil
      saved = config.mappings(Config::KEYBOARD_GUID)
      return @map = DEFAULT_MAP.dup if saved.empty?

      map = {} of String => Button
      saved.each do |gba_str, keysym|
        button = Button.parse?(gba_str)
        map[keysym] = button if button
      end
      @map = map
    end

    def save_to_config(config : Config) : Nil
      @map.each { |input, button| config.set_mapping(Config::KEYBOARD_GUID, button.to_s.downcase, input) }
    end

    def reload!(config : Config) : Nil
      config.reload!
      load_config(config)
    end

    def labels : Hash(Button, String)
      result = {} of Button => String
      @map.each { |input, button| result[button] = input }
      result
    end

    def supports_deadzone? : Bool
      false
    end
  end
end
