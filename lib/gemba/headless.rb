# frozen_string_literal: true

# Lightweight entry point — Tk and SDL2 are NOT loaded.
#
#   require "gemba/headless"
#   Gemba::HeadlessPlayer.open("game.gba") { |p| p.step(60) }

require_relative "runtime"

module Gemba
  # Marker — signals the headless stack is loaded without Tk/SDL2.
  module Headless; end
end
