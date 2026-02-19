# frozen_string_literal: true

require 'set'

module Gemba
  # Virtual keyboard device that tracks key press/release state.
  # Presents the same interface as an SDL gamepad: +button?+ and +closed?+.
  class VirtualKeyboard
    def initialize
      @held = Set.new
    end

    def press(keysym)   = @held.add(keysym)
    def release(keysym) = @held.delete(keysym)
    def button?(keysym) = @held.include?(keysym)
    def closed? = false
  end

end
