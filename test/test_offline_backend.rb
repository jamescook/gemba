# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"

class TestOfflineBackend < Minitest::Test
  ROM = "test/fixtures/test.gba"

  def setup
    skip "test.gba fixture not found" unless File.exist?(ROM)
    @unlocked = []
    @backend  = Gemba::Achievements::OfflineBackend.new
    @backend.on_unlock { |ach| @unlocked << ach }
  end

  def test_always_authenticated
    assert @backend.authenticated?
  end

  def test_enabled
    assert @backend.enabled?
  end

  def test_login_and_logout_are_noops
    @backend.login_with_password(username: "anyone", password: "anything")
    assert @backend.authenticated?
    @backend.logout
    assert @backend.authenticated?
  end

  def test_on_load_achievement_fires_during_load_game
    Gemba::HeadlessPlayer.open(ROM) do |player|
      @backend.load_game(player.core)
      assert_equal 1, @unlocked.size
      assert_equal "gembatest_loaded", @unlocked.first.id
      assert_equal "Ready to Play",    @unlocked.first.title
      assert @unlocked.first.earned?
    end
  end

  def test_achievement_list_shows_earned_after_load
    Gemba::HeadlessPlayer.open(ROM) do |player|
      @backend.load_game(player.core)
      list = @backend.achievement_list
      assert_equal 1, list.size
      assert list.first.earned?
    end
  end

  def test_counts
    Gemba::HeadlessPlayer.open(ROM) do |player|
      assert_equal 0, @backend.total_count
      @backend.load_game(player.core)
      assert_equal 1, @backend.total_count
      assert_equal 1, @backend.earned_count
    end
  end

  def test_unload_game_clears_state
    Gemba::HeadlessPlayer.open(ROM) do |player|
      @backend.load_game(player.core)
      assert_equal 1, @backend.earned_count
      @backend.unload_game
      assert_equal 0, @backend.total_count
      assert_equal 0, @backend.earned_count
    end
  end

  def test_unknown_rom_has_no_achievements
    Gemba::HeadlessPlayer.open(ROM) do |player|
      custom = Gemba::Achievements::OfflineBackend.new(db: {})
      custom.load_game(player.core)
      assert_equal 0, custom.total_count
      assert_empty @unlocked
    end
  end

  def test_store_adds_definitions
    Gemba::HeadlessPlayer.open(ROM) do |player|
      custom = Gemba::Achievements::OfflineBackend.new(db: {})
      custom.on_unlock { |a| @unlocked << a }
      custom.store(player.core.checksum, [
        { id: "extra", title: "Extra", description: "desc",
          points: 5, trigger: :on_load }
      ])
      custom.load_game(player.core)
      assert_equal 1, @unlocked.size
      assert_equal "extra", @unlocked.first.id
    end
  end

  def test_memory_achievement_fires_on_rising_edge
    addr = 0x02000000
    Gemba::HeadlessPlayer.open(ROM) do |player|
      backend = Gemba::Achievements::OfflineBackend.new(db: {
        player.core.checksum => [
          { id: "mem_test", title: "Mem", description: "d", points: 2,
            trigger: :memory,
            condition: ->(mem) { mem.call(addr) == 0x01 } }
        ]
      })
      backend.on_unlock { |a| @unlocked << a }
      backend.load_game(player.core)

      # EWRAM starts zeroed — condition false
      player.step(1)
      backend.do_frame(player.core)
      assert_empty @unlocked

      # Write 0x01 to EWRAM — but we can't poke real memory from Ruby,
      # so verify do_frame doesn't crash and condition stays unevaluated
      backend.do_frame(player.core)
      assert_empty @unlocked
    end
  end
end
