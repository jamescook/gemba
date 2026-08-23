module Gemba
  # Anything KeyboardMap can ask "is this keysym held right now" -
  # different sources (Viewport, VirtualKeyboard) use different method
  # names for the same concept, so this unifies them behind one seam.
  module KeySource
    abstract def button?(key : String) : Bool
  end
end
