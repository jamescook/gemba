# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/achievements"

class TestFakeBackendAuth < Minitest::Test
  def test_any_nonempty_creds_succeed_by_default
    b = Gemba::Achievements::FakeBackend.new
    statuses = []
    b.on_auth_change { |status, _| statuses << status }
    b.login_with_token(username: 'alice', token: 'anything')
    assert b.authenticated?
    assert_equal [:ok], statuses
  end

  def test_empty_username_fails
    b = Gemba::Achievements::FakeBackend.new
    b.login_with_token(username: '', token: 'tok')
    refute b.authenticated?
  end

  def test_empty_token_fails
    b = Gemba::Achievements::FakeBackend.new
    b.login_with_token(username: 'alice', token: '')
    refute b.authenticated?
  end

  def test_restricted_correct_pair_succeeds
    b = Gemba::Achievements::FakeBackend.new(valid_username: 'alice', valid_token: 'secret')
    b.login_with_token(username: 'alice', token: 'secret')
    assert b.authenticated?
  end

  def test_restricted_wrong_user_fails
    b = Gemba::Achievements::FakeBackend.new(valid_username: 'alice', valid_token: 'secret')
    statuses = []
    errors   = []
    b.on_auth_change { |s, e| statuses << s; errors << e }
    b.login_with_token(username: 'bob', token: 'secret')
    refute b.authenticated?
    assert_equal [:error], statuses
    refute_nil errors.first
  end

  def test_restricted_wrong_token_fails
    b = Gemba::Achievements::FakeBackend.new(valid_username: 'alice', valid_token: 'secret')
    b.login_with_token(username: 'alice', token: 'wrong')
    refute b.authenticated?
  end

  def test_logout_clears_auth
    b = Gemba::Achievements::FakeBackend.new
    b.login_with_token(username: 'alice', token: 'tok')
    assert b.authenticated?
    b.logout
    refute b.authenticated?
  end

  def test_multiple_auth_callbacks_all_fired
    b = Gemba::Achievements::FakeBackend.new
    results = []
    b.on_auth_change { |s, _| results << "cb1:#{s}" }
    b.on_auth_change { |s, _| results << "cb2:#{s}" }
    b.login_with_token(username: 'u', token: 't')
    assert_equal ['cb1:ok', 'cb2:ok'], results
  end
end
