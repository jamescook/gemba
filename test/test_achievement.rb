# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/achievements"

class TestAchievement < Minitest::Test
  def test_unearned_by_default
    ach = Gemba::Achievements::Achievement.new(
      id: 'x', title: 'T', description: 'D', points: 10, earned_at: nil
    )
    refute ach.earned?
    assert_nil ach.earned_at
  end

  def test_earn_returns_copy_with_timestamp
    ach = Gemba::Achievements::Achievement.new(
      id: 'x', title: 'T', description: 'D', points: 10, earned_at: nil
    )
    earned = ach.earn
    assert earned.earned?
    assert_instance_of Time, earned.earned_at
  end

  def test_earn_does_not_mutate_original
    ach = Gemba::Achievements::Achievement.new(
      id: 'x', title: 'T', description: 'D', points: 10, earned_at: nil
    )
    ach.earn
    refute ach.earned?
  end
end
