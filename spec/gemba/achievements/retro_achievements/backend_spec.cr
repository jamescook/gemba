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

  it "#fetch_rich_presence_script pulls PatchData.RichPresencePatch" do
    app, backend = build do |_params|
      {JSON.parse(%({"PatchData":{"RichPresencePatch":"Display:\\nIn Littleroot Town"}})), true}
    end

    script = nil
    done = false
    backend.fetch_rich_presence_script("someone", "tok", 515_i64) { |got| script = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    script.should eq "Display:\nIn Littleroot Town"
    app.destroy
  end

  it "#fetch_rich_presence_script yields nil when the game has no script" do
    app, backend = build { |_params| {JSON.parse(%({"PatchData":{"RichPresencePatch":""}})), true} }

    script = "unset"
    done = false
    backend.fetch_rich_presence_script("someone", "tok", 515_i64) { |got| script = got; done = true }
    app.interp.wait_until(5.seconds) { done }

    script.should be_nil
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
