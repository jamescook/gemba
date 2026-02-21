# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/achievements"
require_relative "support/fake_core"

class TestFakeBackendAchievements < Minitest::Test
  ADDR = 0x02000000

  def setup
    @backend = Gemba::Achievements::FakeBackend.new
    @backend.add_achievement(id: 'test', title: 'Test', description: 'desc', points: 5) do |mem|
      mem.call(ADDR) == 0x42
    end
    @core    = FakeCore.new
    @unlocked = []
    @backend.on_unlock { |ach| @unlocked << ach }
  end

  def test_no_unlock_when_condition_false
    @core.poke(ADDR, 0x00)
    @backend.do_frame(@core)
    assert_empty @unlocked
  end

  def test_unlock_fires_when_condition_becomes_true
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal 1, @unlocked.size
    assert_equal 'test', @unlocked.first.id
    assert_equal 'Test',  @unlocked.first.title
    assert_equal 5,       @unlocked.first.points
    assert @unlocked.first.earned?
  end

  def test_unlock_fires_only_once_rising_edge
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    @backend.do_frame(@core)
    assert_equal 1, @unlocked.size
  end

  def test_no_second_unlock_after_condition_cycles
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    @core.poke(ADDR, 0x00)
    @backend.do_frame(@core)
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal 1, @unlocked.size
  end

  def test_fires_on_first_true_frame
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal 1, @unlocked.size
  end

  def test_no_unlock_on_wrong_value
    @core.poke(ADDR, 0x01)
    @backend.do_frame(@core)
    assert_empty @unlocked
  end

  def test_achievement_list_reflects_earned_state
    assert_equal 1, @backend.total_count
    assert_equal 0, @backend.earned_count

    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)

    assert_equal 1, @backend.earned_count
    assert @backend.achievement_list.first.earned?
  end

  def test_multiple_achievements_independent
    @backend.add_achievement(id: 'two', title: 'Two', description: '', points: 10) do |mem|
      mem.call(ADDR + 1) == 0xFF
    end

    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal 1, @unlocked.size
    assert_equal 'test', @unlocked.first.id

    @core.poke(ADDR + 1, 0xFF)
    @backend.do_frame(@core)
    assert_equal 2, @unlocked.size
    assert_equal 'two', @unlocked.last.id
  end

  def test_reset_earned_allows_re_unlock
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal 1, @backend.earned_count

    @backend.reset_earned
    assert_equal 0, @backend.earned_count

    @unlocked.clear
    @core.poke(ADDR, 0x00)
    @backend.do_frame(@core)
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal 1, @unlocked.size
  end

  def test_load_game_resets_earned
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal 1, @backend.earned_count

    @backend.load_game(@core)
    assert_equal 0, @backend.earned_count
  end

  def test_multiple_unlock_callbacks_all_fire
    other = []
    @backend.on_unlock { |ach| other << ach.id }
    @core.poke(ADDR, 0x42)
    @backend.do_frame(@core)
    assert_equal ['test'], @unlocked.map(&:id)
    assert_equal ['test'], other
  end

  def test_enabled
    assert @backend.enabled?
  end
end
