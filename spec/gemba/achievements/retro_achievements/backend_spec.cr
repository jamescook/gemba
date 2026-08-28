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
