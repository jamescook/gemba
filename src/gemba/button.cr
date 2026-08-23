module Gemba
  # Bit order must match mGBA's GBA_KEY_* enum; Core#keys= expects
  # exactly this.
  @[Flags]
  enum Button
    A
    B
    Select
    Start
    Right
    Left
    Up
    Down
    R
    L
  end
end
