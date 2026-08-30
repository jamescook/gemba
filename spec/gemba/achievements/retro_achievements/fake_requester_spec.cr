require "../../../spec_helper"

private def backend_with(fake : Gemba::Achievements::RetroAchievements::FakeRequester)
  session = Tryst::UI::Session.new(title: "fake_requester_spec")
  app = session.run_async.app
  {app, Gemba::Achievements::RetroAchievements::Backend.new(app, fake.to_proc)}
end

describe Gemba::Achievements::RetroAchievements::FakeRequester do
  it "answers the whole login -> gameid -> patch -> unlocks -> award chain the real endpoint would" do
    fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
      game_id: 515_i64, script: "Display:\nIn Littleroot Town",
      achievements: [
        Gemba::Achievements::RetroAchievements::FakeRequester.achievement(1_i64, "0xH0000=1", title: "First"),
        Gemba::Achievements::RetroAchievements::FakeRequester.achievement(2_i64, "0xH0001=1", title: "Second"),
      ],
      unlocked: [2_i64])
    app, backend = backend_with(fake)

    token = nil
    backend.login_with_password("someone", "hunter2") { |got_token, _error| token = got_token }
    app.interp.wait_until(5.seconds) { !token.nil? }
    resolved_token = token.should_not be_nil
    resolved_token.should eq "fake-token-someone"

    game_id = nil
    done = false
    backend.lookup_game_id("anyhash") { |id| game_id = id; done = true }
    app.interp.wait_until(5.seconds) { done }
    game_id.should eq 515_i64

    patch = nil
    done = false
    backend.fetch_patch("someone", resolved_token, 515_i64) { |got| patch = got; done = true }
    app.interp.wait_until(5.seconds) { done }
    got = patch.should_not be_nil
    got.script.should eq "Display:\nIn Littleroot Town"
    got.achievements.map(&.title).should eq ["First", "Second"]

    earned = nil
    done = false
    backend.fetch_unlocks("someone", resolved_token, 515_i64) { |got_earned| earned = got_earned; done = true }
    app.interp.wait_until(5.seconds) { done }
    earned.should eq Set{2_u32}

    ok = nil
    backend.award_achievement("someone", resolved_token, 1_u32) { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }
    ok.should be_true
    fake.awarded_ids.should eq [1_i64]

    # The site remembers - a later unlocks query reports it earned.
    earned = nil
    done = false
    backend.fetch_unlocks("someone", resolved_token, 515_i64) { |got_earned| earned = got_earned; done = true }
    app.interp.wait_until(5.seconds) { done }
    earned.should eq Set{1_u32, 2_u32}

    app.destroy
  end

  it "award_fails refuses unlocks until switched off again, on the same fake" do
    fake = Gemba::Achievements::RetroAchievements::FakeRequester.new
    fake.award_fails = true
    app, backend = backend_with(fake)

    ok = nil
    backend.award_achievement("someone", "tok", 1_u32) { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }
    ok.should be_false

    fake.award_fails = false
    ok = nil
    backend.award_achievement("someone", "tok", 1_u32) { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }
    ok.should be_true

    fake.awarded_ids.should eq [1_i64, 1_i64]
    app.destroy
  end

  it "unlocks_fail makes r=unlocks fail outright" do
    fake = Gemba::Achievements::RetroAchievements::FakeRequester.new
    fake.unlocks_fail = true
    app, backend = backend_with(fake)

    earned = Set{1_u32}.as(Set(UInt32)?)
    done = false
    backend.fetch_unlocks("someone", "tok", 515_i64) { |got| earned = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    earned.should be_nil
    app.destroy
  end

  it "#ping_messages records the presence strings that would have been published" do
    fake = Gemba::Achievements::RetroAchievements::FakeRequester.new
    app, backend = backend_with(fake)

    ok = nil
    backend.ping("someone", "tok", 515_i64, "In Littleroot Town") { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    ok.should be_true
    fake.ping_messages.should eq ["In Littleroot Town"]
    app.destroy
  end

  it "reports an unrecognised ROM when built with no game_id" do
    fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(game_id: nil)
    app, backend = backend_with(fake)

    game_id = 1_i64.as(Int64?)
    done = false
    backend.lookup_game_id("unknown") { |id| game_id = id; done = true }
    app.interp.wait_until(5.seconds) { done }

    game_id.should be_nil
    app.destroy
  end

  it "rejects credentials that don't match a configured valid pair" do
    fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
      valid_username: "alice", valid_token: "secret")
    app, backend = backend_with(fake)

    error = nil
    backend.login_with_password("bob", "wrong") { |_token, got_error| error = got_error }
    app.interp.wait_until(5.seconds) { !error.nil? }
    error.should eq "Invalid User/Password combination."

    token = nil
    backend.login_with_password("alice", "secret") { |got_token, _error| token = got_token }
    app.interp.wait_until(5.seconds) { !token.nil? }
    token.should eq "fake-token-alice"

    app.destroy
  end

  it "offline: true exercises the connection-failure path" do
    fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(offline: true)
    app, backend = backend_with(fake)

    error = nil
    backend.login_with_password("someone", "hunter2") { |_token, got_error| error = got_error }
    app.interp.wait_until(5.seconds) { !error.nil? }

    error.should eq "Could not connect to RetroAchievements"
    app.destroy
  end
end
