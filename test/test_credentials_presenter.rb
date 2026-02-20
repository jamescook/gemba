# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"

class TestCredentialsPresenter < Minitest::Test
  def setup
    Gemba.bus = Gemba::EventBus.new
    @config = Gemba::Config.new(path: nil)  # in-memory defaults
  end

  def presenter(**overrides)
    cfg = @config
    cfg.ra_enabled  = overrides.fetch(:enabled,  false)
    cfg.ra_username = overrides.fetch(:username, '')
    cfg.ra_token    = overrides.fetch(:token,    '')
    Gemba::Achievements::CredentialsPresenter.new(cfg)
  end

  # -- Disabled state ----------------------------------------------------------

  def test_disabled_everything_off
    p = presenter(enabled: false)
    assert_equal :disabled, p.fields_state
    assert_equal :disabled, p.login_button_state
    assert_equal :disabled, p.verify_button_state
    assert_equal :disabled, p.logout_button_state
    assert_equal :disabled, p.reset_button_state
    assert_equal :empty,    p.feedback[:key]
  end

  # -- Enabled, not logged in --------------------------------------------------

  def test_enabled_no_token_fields_editable
    p = presenter(enabled: true)
    assert_equal :normal, p.fields_state
  end

  def test_enabled_no_token_login_disabled_when_fields_empty
    p = presenter(enabled: true)
    assert_equal :disabled, p.login_button_state
    assert_equal :disabled, p.verify_button_state
  end

  def test_enabled_login_enabled_when_fields_filled
    p = presenter(enabled: true)
    p.username = 'alice'
    p.password = 'secret'
    assert_equal :normal,   p.login_button_state
    assert_equal :disabled, p.verify_button_state  # no token yet — verify stays disabled
  end

  def test_enabled_login_disabled_with_only_username
    p = presenter(enabled: true)
    p.username = 'alice'
    assert_equal :disabled, p.login_button_state
  end

  def test_enabled_login_disabled_with_only_password
    p = presenter(enabled: true)
    p.password = 'secret'
    assert_equal :disabled, p.login_button_state
  end

  def test_enabled_no_token_logout_and_reset_disabled
    p = presenter(enabled: true)
    assert_equal :disabled, p.logout_button_state
    assert_equal :disabled, p.reset_button_state
  end

  def test_enabled_no_token_feedback_not_logged_in
    p = presenter(enabled: true)
    assert_equal :not_logged_in, p.feedback[:key]
  end

  # -- Enabled, logged in (token present) --------------------------------------

  def test_logged_in_fields_disabled
    p = presenter(enabled: true, username: 'alice', token: 'tok123')
    assert_equal :readonly, p.fields_state
  end

  def test_logged_in_login_disabled
    p = presenter(enabled: true, username: 'alice', token: 'tok123')
    assert_equal :disabled, p.login_button_state
  end

  def test_logged_in_verify_enabled
    p = presenter(enabled: true, username: 'alice', token: 'tok123')
    assert_equal :normal, p.verify_button_state
  end

  def test_logged_in_logout_and_reset_enabled
    p = presenter(enabled: true, username: 'alice', token: 'tok123')
    assert_equal :normal, p.logout_button_state
    assert_equal :normal, p.reset_button_state
  end

  def test_logged_in_feedback_shows_username
    p = presenter(enabled: true, username: 'alice', token: 'tok123')
    fb = p.feedback
    assert_equal :logged_in_as, fb[:key]
    assert_equal 'alice',       fb[:username]
  end

  # -- State mutations ----------------------------------------------------------

  def test_enabling_clears_disabled_state
    p = presenter(enabled: false)
    assert_equal :disabled, p.fields_state
    p.enabled = true
    assert_equal :normal, p.fields_state
  end

  def test_credentials_changed_emitted_on_mutations
    p = presenter(enabled: false)
    fired = 0
    Gemba.bus.on(:credentials_changed) { fired += 1 }
    p.enabled  = true
    p.username = 'alice'
    p.password = 'pw'
    assert_equal 3, fired
  end

  # -- Auth result handling (via :ra_auth_result bus events) -------------------

  def auth(status, token: nil, message: nil)
    Gemba.bus.emit(:ra_auth_result, status: status, token: token, message: message)
  end

  def test_login_success_stores_token_and_clears_password
    p = presenter(enabled: true, username: 'alice')
    p.password = 'pw'
    auth(:ok, token: 'real_token')
    assert_equal 'real_token', p.token
    assert_equal '',           p.password
    assert p.logged_in?
  end

  def test_login_success_locks_fields
    p = presenter(enabled: true, username: 'alice')
    auth(:ok, token: 'tok')
    assert_equal :readonly, p.fields_state
    assert_equal :normal,   p.logout_button_state
    assert_equal :normal,   p.verify_button_state
  end

  def test_login_error_sets_feedback
    p = presenter(enabled: true, username: 'alice')
    auth(:error, message: 'Bad credentials')
    assert_equal :error,            p.feedback[:key]
    assert_equal 'Bad credentials', p.feedback[:message]
  end

  def test_login_error_does_not_affect_button_states
    p = presenter(enabled: true, username: 'alice')
    p.password = 'pw'
    auth(:error, message: 'Bad credentials')
    # Fields and login button should still be enabled
    assert_equal :normal, p.fields_state
    assert_equal :normal, p.login_button_state
  end

  def test_logout_clears_token_keeps_username
    p = presenter(enabled: true, username: 'alice', token: 'tok')
    auth(:logout)
    assert_equal '',      p.token
    assert_equal 'alice', p.username  # kept so user can re-enter password
    refute p.logged_in?
  end

  def test_logout_re_enables_fields
    p = presenter(enabled: true, username: 'alice', token: 'tok')
    auth(:logout)
    assert_equal :normal, p.fields_state
  end

  # -- Transient feedback -------------------------------------------------------

  def test_transient_overrides_normal_feedback
    p = presenter(enabled: true, username: 'alice', token: 'tok')
    p.show_transient(:test_ok)
    assert_equal :test_ok, p.feedback[:key]
  end

  def test_clear_transient_restores_normal_feedback
    p = presenter(enabled: true, username: 'alice', token: 'tok')
    p.show_transient(:test_ok)
    p.clear_transient
    assert_equal :logged_in_as, p.feedback[:key]
  end
end
