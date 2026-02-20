# frozen_string_literal: true

module Gemba
  module Platform
    class GBA
      def width         = 240
      def height        = 160
      def fps           = 59.7272
      def fps_fraction  = [262144, 4389]
      def aspect        = [3, 2]
      def name          = "Game Boy Advance"
      def short_name    = "GBA"
      def buttons       = %i[a b l r start select up down left right]
      def thumb_size    = [120, 80]

      def ==(other)  = other.is_a?(Platform::GBA)
      def eql?(other) = self == other
      def hash        = self.class.hash
    end
  end
end
