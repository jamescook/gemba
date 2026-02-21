# frozen_string_literal: true

module Gemba
  module Achievements
    # Represents a single achievement (earned or unearned).
    #
    # @attr [String]  id          Unique identifier (string, arbitrary)
    # @attr [String]  title       Short display name
    # @attr [String]  description What the player must do to earn it
    # @attr [Integer] points      RA point value (or custom weight)
    # @attr [Time, nil] earned_at When it was unlocked; nil if unearned
    Achievement = Data.define(:id, :title, :description, :points, :earned_at) do
      def earned?
        !earned_at.nil?
      end

      # Return a copy marked as earned right now.
      def earn
        with(earned_at: Time.now)
      end
    end
  end
end
