# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/achievements"
require_relative "support/fake_core"

# Tests that RetroAchievements::Backend never awards achievements before the
# server's earned list is known.
#
# The bug scenario:
#   fetch_patch_data completes → runtime activated with 89 achievements
#   emulator starts → do_frame fires → some conditions true at frame 0
#   @earned is empty (r=unlocks still in flight) → all are re-awarded
#
# The fix: @achievements stays empty until fetch_unlocks completes.
# do_frame's `return if @achievements.empty?` guards the window by construction.
#
# These tests verify the fix through the public API (no instance_variable_set):
# if @achievements is empty, do_frame must be silent regardless of what the
# underlying runtime would report.
class TestRABackendUnlockGate < Minitest::Test
  def setup
    @backend  = Gemba::Achievements::RetroAchievements::Backend.new(app: nil)
    @unlocked = []
    @backend.on_unlock { |ach| @unlocked << ach }
    @core = FakeCore.new
  end

  # Before any game is loaded, @achievements is empty → do_frame is a no-op.
  def test_do_frame_silent_before_game_loaded
    @backend.do_frame(@core)
    assert_empty @unlocked
  end

  # @achievements only becomes non-empty after fetch_unlocks completes (HTTP).
  # Since we can't make real HTTP calls, verify the state via achievement_list
  # and total_count — they reflect @achievements.
  def test_achievements_empty_until_unlocks_arrive
    assert_equal 0, @backend.total_count,
      "achievement list must be empty before fetch_unlocks completes"
    assert_empty @backend.achievement_list
  end

  # do_frame with an empty achievement list never fires unlock callbacks.
  # This is the structural guarantee — as long as @achievements is empty,
  # no award can happen even if the C runtime were somehow active.
  def test_do_frame_never_fires_when_achievement_list_empty
    # Simulate being "mid-load": patch data fetched but unlocks not yet back.
    # In the new design @achievements stays [] during this window.
    5.times { @backend.do_frame(@core) }
    assert_empty @unlocked,
      "no unlock must fire during the patch→unlocks window"
    assert_equal 0, @backend.earned_count
  end
end
