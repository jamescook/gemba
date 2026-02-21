# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require_relative "support/fake_ra_runtime"
require_relative "support/fake_requester"
require_relative "support/fake_core"

PATCH_RESPONSE = {
  "PatchData" => {
    "RichPresencePatch" => "",
    "Achievements" => [
      { "ID" => 101, "Title" => "First Blood", "Description" => "Get a kill",
        "Points" => 5, "MemAddr" => "0=1", "Flags" => 3 },
      { "ID" => 102, "Title" => "Survivor",    "Description" => "Survive 60s",
        "Points" => 10, "MemAddr" => "1=1", "Flags" => 3 },
    ],
  },
}.freeze

# Tests for Gemba::Achievements::RetroAchievements::Backend.
#
# FakeRequester replaces BackgroundWork so all HTTP callbacks fire synchronously
# in-process — no Tk event loop, no subprocesses, no wait_until.
class TestRABackend < Minitest::Test
  Backend = Gemba::Achievements::RetroAchievements::Backend

  def setup
    @rt  = FakeRARuntime.new
    @req = FakeRequester.new
    @b   = Backend.new(app: nil, runtime: @rt, requester: @req)
  end

  # Authenticate @b via the real login_with_token path.
  def login(username: "user", token: "tok")
    @req.stub(r: "login2", body: { "Success" => true })
    @b.login_with_token(username: username, token: token)
  end

  # Drive the full gameid→patch→unlocks chain.
  def load_game(earned_ids: [], patch: PATCH_RESPONSE)
    @req.stub(r: "gameid",  body: { "GameID" => 42 })
    @req.stub(r: "patch",   body: patch)
    @req.stub(r: "unlocks", body: { "Success" => true, "UserUnlocks" => earned_ids })
    Dir.mktmpdir do |dir|
      rom = File.join(dir, "test.gba")
      File.write(rom, "FAKEGBAROM")
      @b.load_game(nil, rom, "deadbeef" * 4)
    end
  end

  # ---------------------------------------------------------------------------
  # Initial state
  # ---------------------------------------------------------------------------

  def test_not_authenticated_by_default
    refute @b.authenticated?
  end

  def test_enabled
    assert @b.enabled?
  end

  def test_achievement_list_empty_before_game_load
    assert_empty @b.achievement_list
  end

  def test_rich_presence_message_nil_initially
    assert_nil @b.rich_presence_message
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  def test_login_with_password_success
    @req.stub(r: "login2", body: { "Success" => true, "Token" => "tok123" })
    result = nil
    @b.on_auth_change { |status, payload| result = [status, payload] }
    @b.login_with_password(username: "user", password: "hunter2")

    assert_equal :ok,      result[0]
    assert_equal "tok123", result[1]
    assert @b.authenticated?
  end

  def test_login_with_password_failure
    @req.stub(r: "login2", body: { "Success" => false, "Error" => "Invalid credentials" })
    result = nil
    @b.on_auth_change { |status, msg| result = [status, msg] }
    @b.login_with_password(username: "user", password: "wrong")

    assert_equal :error, result[0]
    assert_match(/invalid credentials/i, result[1])
    refute @b.authenticated?
  end

  def test_login_with_token_success
    result = nil
    @b.on_auth_change { |status, _| result = status }
    login
    assert_equal :ok, result
    assert @b.authenticated?
  end

  def test_login_with_token_failure
    @req.stub(r: "login2", body: { "Success" => false, "Error" => "Token invalid" })
    result = nil
    @b.on_auth_change { |status, msg| result = [status, msg] }
    @b.login_with_token(username: "user", token: "bad")

    assert_equal :error, result[0]
    refute @b.authenticated?
  end

  def test_token_test_success
    login
    result = nil
    @b.on_auth_change { |status, _| result = status }
    @b.token_test
    assert_equal :ok, result
  end

  def test_token_test_failure
    login
    @req.stub(r: "login2", body: { "Success" => false, "Error" => "Token invalid" })
    result = nil
    @b.on_auth_change { |status, _| result = status }
    @b.token_test
    assert_equal :error, result
    refute @b.authenticated?
  end

  def test_logout_clears_auth_state
    login
    @b.logout
    refute @b.authenticated?
    assert_empty @b.achievement_list
  end

  # ---------------------------------------------------------------------------
  # Game load chain
  # ---------------------------------------------------------------------------

  def test_load_game_skipped_when_not_authenticated
    load_game
    assert_empty @b.achievement_list
    refute @req.requested?("gameid"), "should not hit network when unauthenticated"
  end

  def test_load_game_populates_achievement_list
    login
    load_game

    assert_equal 2, @b.total_count
    assert_equal "101", @b.achievement_list[0].id
    assert_equal "102", @b.achievement_list[1].id
    assert_equal 2, @rt.count
  end

  def test_load_game_marks_preearned_achievements
    login
    load_game(earned_ids: [101])

    list = @b.achievement_list
    assert list.find { |a| a.id == "101" }&.earned?, "101 should be earned"
    refute list.find { |a| a.id == "102" }&.earned?, "102 should not be earned"
    assert_includes @rt.deactivated, "101"
  end

  def test_load_game_aborts_when_game_id_zero
    login
    @req.stub(r: "gameid", body: { "GameID" => 0 })
    Dir.mktmpdir do |dir|
      rom = File.join(dir, "test.gba")
      File.write(rom, "FAKE")
      @b.load_game(nil, rom, "deadbeef" * 4)
    end

    assert_empty @b.achievement_list
    refute @req.requested?("patch"), "patch must not be requested when GameID is 0"
  end

  def test_load_game_activates_rich_presence_script
    rp_patch = PATCH_RESPONSE.merge(
      "PatchData" => PATCH_RESPONSE["PatchData"].merge("RichPresencePatch" => "Display: Hello")
    )
    login
    load_game(patch: rp_patch)

    assert_equal "Display: Hello", @rt.rp_script
  end

  def test_unload_game_clears_achievement_list
    login
    load_game
    @b.unload_game
    assert_empty @b.achievement_list
  end

  def test_sync_unlocks_repopulates_list
    login
    load_game

    # Re-stub for the sync re-fetch
    @req.stub(r: "patch",   body: PATCH_RESPONSE)
    @req.stub(r: "unlocks", body: { "Success" => true, "UserUnlocks" => [102] })
    @b.sync_unlocks

    list = @b.achievement_list
    refute list.find { |a| a.id == "101" }&.earned?
    assert list.find { |a| a.id == "102" }&.earned?
  end

  # ---------------------------------------------------------------------------
  # do_frame
  # ---------------------------------------------------------------------------

  def test_do_frame_silent_before_game_loaded
    unlocked = []
    @b.on_unlock { |a| unlocked << a }
    @b.do_frame(FakeCore.new)
    assert_empty unlocked
  end

  def test_do_frame_fires_unlock_and_submits_to_server
    login
    load_game

    @req.stub(r: "awardachievement", body: { "Success" => true })
    @rt.queue_triggers("101")

    unlocked = []
    @b.on_unlock { |a| unlocked << a }
    @b.do_frame(FakeCore.new)

    assert_equal 1, unlocked.size
    assert_equal "101", unlocked.first.id
    assert @req.requested?("awardachievement")
    assert_equal "101", @req.requests_for("awardachievement").first[:a].to_s
  end

  def test_do_frame_skips_already_earned_achievement
    login
    load_game(earned_ids: [101])

    @rt.queue_triggers("101")
    unlocked = []
    @b.on_unlock { |a| unlocked << a }
    @b.do_frame(FakeCore.new)

    assert_empty unlocked, "already-earned achievement must not fire again"
    refute @req.requested?("awardachievement")
  end

  def test_do_frame_rich_presence_fires_callback_when_enabled
    login
    load_game

    @rt.rp_message = "Playing Stage 1"
    @b.rich_presence_enabled = true
    @b.instance_variable_set(:@rp_eval_frame, 239)

    fired = []
    @b.on_rich_presence_changed { |m| fired << m }
    @b.do_frame(FakeCore.new)

    assert_equal ["Playing Stage 1"], fired
    assert_equal "Playing Stage 1", @b.rich_presence_message
  end

  def test_do_frame_rich_presence_silent_when_disabled
    login
    load_game

    @rt.rp_message = "Playing Stage 1"
    @b.rich_presence_enabled = false
    @b.instance_variable_set(:@rp_eval_frame, 239)

    fired = []
    @b.on_rich_presence_changed { |m| fired << m }
    @b.do_frame(FakeCore.new)

    assert_empty fired
  end

  # ---------------------------------------------------------------------------
  # FakeRARuntime self-tests
  # ---------------------------------------------------------------------------

  def test_fake_runtime_activate_deactivate
    @rt.activate("101", "0=1")
    @rt.activate("102", "1=1")
    assert_equal 2, @rt.count
    @rt.deactivate("101")
    assert_equal 1, @rt.count
    refute @rt.activated.key?("101")
  end

  def test_fake_runtime_clear_resets_state
    @rt.activate("101", "0=1")
    @rt.queue_triggers("101")
    @rt.clear
    assert_equal 0, @rt.count
    assert_empty @rt.do_frame(nil)
  end

  def test_fake_runtime_queue_consumed_once
    @rt.queue_triggers("101")
    assert_equal ["101"], @rt.do_frame(nil)
    assert_empty @rt.do_frame(nil)
  end
end
