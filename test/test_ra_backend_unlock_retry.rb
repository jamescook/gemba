# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require_relative "support/fake_ra_runtime"
require_relative "support/fake_requester"
require_relative "support/fake_core"

# Tests for the unlock retry queue in RetroAchievements::Backend.
#
# FakeRequester fires on_progress synchronously so no event loop is needed.
# For worker-style calls (drain_unlock_queue) it yields [ok, id] to match
# what UnlockRetryWorker produces in production.
class TestRABackendUnlockRetry < Minitest::Test
  Backend = Gemba::Achievements::RetroAchievements::Backend

  PATCH = {
    "PatchData" => {
      "RichPresencePatch" => "",
      "Achievements" => [
        { "ID" => 101, "Title" => "First Blood", "Description" => "Kill",
          "Points" => 5, "MemAddr" => "0=1", "Flags" => 3 },
        { "ID" => 102, "Title" => "Survivor", "Description" => "Survive",
          "Points" => 10, "MemAddr" => "1=1", "Flags" => 3 },
      ],
    },
  }.freeze

  def setup
    @rt  = FakeRARuntime.new
    @req = FakeRequester.new
    @b   = Backend.new(app: nil, runtime: @rt, requester: @req)
  end

  def login_and_load
    @req.stub(r: "login2",  body: { "Success" => true })
    @req.stub(r: "gameid",  body: { "GameID" => 42 })
    @req.stub(r: "patch",   body: PATCH)
    @req.stub(r: "unlocks", body: { "Success" => true, "UserUnlocks" => [] })
    @b.login_with_token(username: "user", token: "tok")
    Dir.mktmpdir do |dir|
      rom = File.join(dir, "test.gba")
      File.write(rom, "FAKEGBA")
      @b.load_game(nil, rom, "deadbeef" * 4)
    end
  end

  # -- Queue builds on initial failure ----------------------------------------

  def test_failed_unlock_enqueues_for_retry
    login_and_load
    @req.stub(r: "awardachievement", ok: false, body: { "Success" => false })
    @rt.queue_triggers("101")
    @b.do_frame(FakeCore.new)
    assert_equal 1, @b.unlock_queue.size
    assert_equal "101", @b.unlock_queue.first[:id]
  end

  def test_successful_unlock_does_not_enqueue
    login_and_load
    @req.stub(r: "awardachievement", ok: true, body: { "Success" => true })
    @rt.queue_triggers("101")
    @b.do_frame(FakeCore.new)
    assert_empty @b.unlock_queue
  end

  def test_multiple_failed_unlocks_all_enqueue
    login_and_load
    @req.stub(r: "awardachievement", ok: false, body: { "Success" => false })
    @rt.queue_triggers("101", "102")
    @b.do_frame(FakeCore.new)
    assert_equal 2, @b.unlock_queue.size
  end

  # -- drain_unlock_queue -----------------------------------------------------

  def test_drain_sends_retry_request_per_entry
    login_and_load
    @req.stub(r: "awardachievement", ok: true, body: { "Success" => true })
    @b.unlock_queue << { id: "101", hardcore: false }
    @b.unlock_queue << { id: "102", hardcore: false }
    @b.drain_unlock_queue
    assert_equal 2, @req.requests_for("awardachievement").size
  end

  def test_drain_clears_queue_on_success
    login_and_load
    @req.stub(r: "awardachievement", ok: true, body: { "Success" => true })
    @b.unlock_queue << { id: "101", hardcore: false }
    @b.drain_unlock_queue
    assert_empty @b.unlock_queue
  end

  def test_drain_keeps_queue_on_failure
    login_and_load
    @req.stub(r: "awardachievement", ok: false, body: { "Success" => false })
    @b.unlock_queue << { id: "101", hardcore: false }
    @b.drain_unlock_queue
    assert_equal 1, @b.unlock_queue.size
  end

  def test_drain_partial_success_removes_only_succeeded
    login_and_load
    @req.stub_queue(r: "awardachievement", ok: true,  body: { "Success" => true })
    @req.stub_queue(r: "awardachievement", ok: false, body: { "Success" => false })
    @b.unlock_queue << { id: "101", hardcore: false }
    @b.unlock_queue << { id: "102", hardcore: false }
    @b.drain_unlock_queue
    assert_equal 1, @b.unlock_queue.size
    assert_equal "102", @b.unlock_queue.first[:id]
  end

  # -- shutdown ---------------------------------------------------------------

  def test_shutdown_logs_pending_and_does_not_raise
    @b.unlock_queue << { id: "101", hardcore: false }
    @b.shutdown
  end

  def test_shutdown_with_empty_queue_does_not_raise
    @b.shutdown
  end
end
