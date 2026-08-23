require "./key_source"

module Gemba
  # Presents the same #button?(name) interface as a real
  # Tryst::SDL::Gamepad, so KeyboardMap treats both uniformly. Never
  # touches Tk/SDL itself.
  class VirtualKeyboard
    include KeySource

    def initialize
      @held = Set(String).new
    end

    def press(keysym : String) : Nil
      @held.add(keysym)
    end

    def release(keysym : String) : Nil
      @held.delete(keysym)
    end

    def button?(key : String) : Bool
      @held.includes?(key)
    end
  end
end
