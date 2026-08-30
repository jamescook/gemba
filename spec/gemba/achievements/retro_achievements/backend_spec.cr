require "../../../spec_helper"

private def build(&requester : Hash(String, String) -> {JSON::Any?, Bool}) : {Tryst::App, Gemba::Achievements::RetroAchievements::Backend}
  session = Tryst::UI::Session.new(title: "ra_backend_spec")
  app = session.run_async.app
  backend = Gemba::Achievements::RetroAchievements::Backend.new(app, requester)
  {app, backend}
end

describe Gemba::Achievements::RetroAchievements::Backend do
  it "#login_with_password stores the token on r=login2 success" do
    app, backend = build { |_params| {JSON.parse(%({"Success":true,"Token":"tok123"})), true} }

    token = nil
    error = nil
    backend.login_with_password("someone", "hunter2") { |got_token, got_error| token = got_token; error = got_error }
    app.interp.wait_until(5.seconds) { !token.nil? || !error.nil? }

    token.should eq "tok123"
    error.should be_nil
    app.destroy
  end

  it "#login_with_password surfaces the server's error message on failure" do
    app, backend = build { |_params| {JSON.parse(%({"Success":false,"Error":"Invalid User/Password combination."})), true} }

    token = nil
    error = nil
    backend.login_with_password("someone", "wrong") { |got_token, got_error| token = got_token; error = got_error }
    app.interp.wait_until(5.seconds) { !token.nil? || !error.nil? }

    token.should be_nil
    error.should eq "Invalid User/Password combination."
    app.destroy
  end

  it "#login_with_password reports a connection error when the request itself fails" do
    app, backend = build { |_params| {nil, false} }

    error = nil
    backend.login_with_password("someone", "hunter2") { |_t, e| error = e }
    app.interp.wait_until(5.seconds) { !error.nil? }

    error.should eq "Could not connect to RetroAchievements"
    app.destroy
  end

  it "#verify_token reports success for a valid stored token" do
    app, backend = build { |_params| {JSON.parse(%({"Success":true})), true} }

    ok = nil
    backend.verify_token("someone", "tok123") { |success, _e| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    ok.should be_true
    app.destroy
  end

  it "#verify_token reports failure for a revoked token" do
    app, backend = build { |_params| {JSON.parse(%({"Success":false,"Error":"Invalid token."})), true} }

    ok = nil
    error = nil
    backend.verify_token("someone", "stale") { |success, e| ok = success; error = e }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    ok.should be_false
    error.should eq "Invalid token."
    app.destroy
  end
end

describe "rich presence requests" do
  it "#lookup_game_id returns the GameID for a known ROM hash" do
    app, backend = build { |_params| {JSON.parse(%({"Success":true,"GameID":515})), true} }

    game_id = nil
    done = false
    backend.lookup_game_id("abc123") { |id| game_id = id; done = true }
    app.interp.wait_until(5.seconds) { done }

    game_id.should eq 515_i64
    app.destroy
  end

  it "#lookup_game_id yields nil for an unrecognised ROM (GameID 0)" do
    app, backend = build { |_params| {JSON.parse(%({"Success":true,"GameID":0})), true} }

    game_id = 999_i64.as(Int64?)
    done = false
    backend.lookup_game_id("nope") { |id| game_id = id; done = true }
    app.interp.wait_until(5.seconds) { done }

    game_id.should be_nil
    app.destroy
  end

  it "#lookup_game_id yields nil when the request fails" do
    app, backend = build { |_params| {nil, false} }

    game_id = 999_i64.as(Int64?)
    done = false
    backend.lookup_game_id("abc123") { |id| game_id = id; done = true }
    app.interp.wait_until(5.seconds) { done }

    game_id.should be_nil
    app.destroy
  end

  it "#fetch_patch pulls the script and the filtered achievement list out of PatchData" do
    patch_json = <<-'JSON'
      {"PatchData":{"RichPresencePatch":"Display:\nIn Littleroot Town","Achievements":[
        {"ID":1,"Title":"First","Description":"d","Points":5,"MemAddr":"0xH0000=1","Flags":3},
        {"ID":2,"Title":"Unofficial","Points":1,"MemAddr":"0xH0001=1","Flags":5}
      ]}}
      JSON
    app, backend = build { |_params| {JSON.parse(patch_json), true} }

    patch = nil
    done = false
    backend.fetch_patch("someone", "tok", 515_i64) { |got| patch = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    got = patch.should_not be_nil
    got.script.should eq "Display:\nIn Littleroot Town"
    got.achievements.map(&.id).should eq [1_u32]
    got.achievements[0].title.should eq "First"
    got.achievements[0].memaddr.should eq "0xH0000=1"
    app.destroy
  end

  it "#fetch_patch include_unofficial: true keeps the Flags 5 entries too" do
    patch_json = <<-JSON
      {"PatchData":{"RichPresencePatch":"","Achievements":[
        {"ID":1,"Title":"First","Points":5,"MemAddr":"0xH0000=1","Flags":3},
        {"ID":2,"Title":"Unofficial","Points":1,"MemAddr":"0xH0001=1","Flags":5}
      ]}}
      JSON
    app, backend = build { |_params| {JSON.parse(patch_json), true} }

    patch = nil
    done = false
    backend.fetch_patch("someone", "tok", 515_i64, include_unofficial: true) { |got| patch = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    got = patch.should_not be_nil
    got.script.should be_nil
    got.achievements.map(&.id).should eq [1_u32, 2_u32]
    app.destroy
  end

  it "#fetch_patch yields nil when the request fails" do
    app, backend = build { |_params| {nil, false} }

    patch = "unset".as((Gemba::Achievements::RetroAchievements::Backend::Patch | String)?)
    done = false
    backend.fetch_patch("someone", "tok", 515_i64) { |got| patch = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    patch.should be_nil
    app.destroy
  end

  it "#fetch_unlocks sends h=0 and yields the already-earned ids" do
    sent = nil
    app, backend = build do |params|
      sent = params
      {JSON.parse(%({"Success":true,"GameID":515,"UserUnlocks":[3,"7"]})), true}
    end

    earned = nil
    done = false
    backend.fetch_unlocks("someone", "tok", 515_i64) { |got| earned = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    earned.should eq Set{3_u32, 7_u32}
    params = sent.should_not be_nil
    params["r"].should eq "unlocks"
    params["g"].should eq "515"
    params["h"].should eq "0"
    app.destroy
  end

  it "#fetch_unlocks yields nil (not an empty set) when the server refuses" do
    app, backend = build { |_params| {JSON.parse(%({"Success":false,"Error":"Invalid token."})), true} }

    earned = Set{1_u32}.as(Set(UInt32)?)
    done = false
    backend.fetch_unlocks("someone", "tok", 515_i64) { |got| earned = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    earned.should be_nil
    app.destroy
  end

  it "#award_achievement posts a=<id> h=0 and reports the server's acceptance" do
    sent = nil
    app, backend = build do |params|
      sent = params
      {JSON.parse(%({"Success":true,"AchievementID":42,"Score":1234})), true}
    end

    ok = nil
    backend.award_achievement("someone", "tok", 42_u32) { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    ok.should be_true
    params = sent.should_not be_nil
    params["r"].should eq "awardachievement"
    params["a"].should eq "42"
    params["h"].should eq "0"
    app.destroy
  end

  it "#award_achievement hardcore: true sends h=1" do
    sent = nil
    app, backend = build do |params|
      sent = params
      {JSON.parse(%({"Success":true})), true}
    end

    ok = nil
    backend.award_achievement("someone", "tok", 42_u32, hardcore: true) { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    sent.should_not(be_nil).["h"].should eq "1"
    app.destroy
  end

  it "#award_achievement reports false when the server refuses the unlock" do
    app, backend = build { |_params| {JSON.parse(%({"Success":false,"Error":"Achievement not found"})), true} }

    ok = nil
    backend.award_achievement("someone", "tok", 42_u32) { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    ok.should be_false
    app.destroy
  end

  it "#award_achievement reports false when the request itself fails" do
    app, backend = build { |_params| {nil, false} }

    ok = nil
    backend.award_achievement("someone", "tok", 42_u32) { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    ok.should be_false
    app.destroy
  end

  it "#ping sends the presence string as m= and reports success" do
    sent = nil
    app, backend = build do |params|
      sent = params
      {JSON.parse(%({"Success":true})), true}
    end

    ok = nil
    backend.ping("someone", "tok", 515_i64, "In Littleroot Town") { |success| ok = success }
    app.interp.wait_until(5.seconds) { !ok.nil? }

    ok.should be_true
    params = sent.should_not be_nil
    params["r"].should eq "ping"
    params["g"].should eq "515"
    params["m"].should eq "In Littleroot Town"
    app.destroy
  end
end
