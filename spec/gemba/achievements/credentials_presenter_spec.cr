require "../../spec_helper"

private def config_with(username : String = "", token : String = "", enabled : Bool = false) : Gemba::Config
  config = Gemba::Config.new(File.tempname("credentials_presenter_spec", ".json"))
  config.ra_enabled = enabled
  config.ra_username = username
  config.ra_token = token
  config
end

describe Gemba::Achievements::CredentialsPresenter do
  it "#with_defaults starts disabled, logged out, with empty fields" do
    presenter = Gemba::Achievements::CredentialsPresenter.with_defaults
    presenter.enabled?.should be_false
    presenter.logged_in?.should be_false
    presenter.username.should eq ""
    presenter.fields_state.should eq :disabled
    presenter.login_button_state.should eq :disabled
    presenter.feedback.key.should eq :empty
  end

  it "seeds from Config when a token is already saved" do
    presenter = Gemba::Achievements::CredentialsPresenter.new(config_with(username: "someone", token: "tok123", enabled: true))
    presenter.logged_in?.should be_true
    presenter.fields_state.should eq :readonly
    presenter.feedback.key.should eq :logged_in_as
    presenter.feedback.username.should eq "someone"
  end

  it "enables the login button only once enabled, username, and password are all filled" do
    presenter = Gemba::Achievements::CredentialsPresenter.new(config_with(enabled: true))
    presenter.login_button_state.should eq :disabled

    presenter.username = "someone"
    presenter.login_button_state.should eq :disabled

    presenter.password = "hunter2"
    presenter.login_button_state.should eq :normal
  end

  it "#login_succeeded stores the token, clears the password, and swaps to readonly" do
    presenter = Gemba::Achievements::CredentialsPresenter.new(config_with(enabled: true, username: "someone"))
    presenter.password = "hunter2"

    presenter.login_succeeded("tok123")

    presenter.token.should eq "tok123"
    presenter.password.should eq ""
    presenter.logged_in?.should be_true
    presenter.fields_state.should eq :readonly
    presenter.verify_button_state.should eq :normal
    presenter.logout_button_state.should eq :normal
  end

  it "#logged_out clears the token and password but keeps the username" do
    presenter = Gemba::Achievements::CredentialsPresenter.new(config_with(username: "someone", token: "tok123", enabled: true))

    presenter.logged_out

    presenter.logged_in?.should be_false
    presenter.username.should eq "someone"
    presenter.token.should eq ""
    presenter.fields_state.should eq :normal
  end

  it "#auth_failed surfaces the error message as feedback" do
    presenter = Gemba::Achievements::CredentialsPresenter.new(config_with(enabled: true))
    presenter.auth_failed("Invalid credentials")
    presenter.feedback.key.should eq :error
    presenter.feedback.message.should eq "Invalid credentials"
  end
end
