# frozen_string_literal: true

module Gemba
  module Platform
    # Same hardware specs as GB (resolution, FPS, buttons).
    # Separate class for distinct name and future color-specific behavior.
    class GBC
      def width         = 160
      def height        = 144
      def fps           = 59.7275
      def fps_fraction  = [4194304, 70224]
      def aspect        = [10, 9]
      def name          = "Game Boy Color"
      def short_name    = "GBC"
      def buttons       = %i[a b start select up down left right]
      def thumb_size    = [80, 72]

      def ==(other)  = other.is_a?(Platform::GBC)
      def eql?(other) = self == other
      def hash        = self.class.hash
    end
  end
end
