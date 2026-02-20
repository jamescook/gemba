# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/achievements"
require_relative "support/fake_core"

class TestNullBackend < Minitest::Test
  def setup
    @b = Gemba::Achievements::NullBackend.new
  end

  def test_not_enabled
    refute @b.enabled?
  end

  def test_not_authenticated
    refute @b.authenticated?
  end

  def test_achievement_list_empty
    assert_equal [], @b.achievement_list
  end

  def test_counts_zero
    assert_equal 0, @b.earned_count
    assert_equal 0, @b.total_count
  end

  def test_do_frame_is_noop
    assert_nil @b.do_frame(FakeCore.new)
  end

  def test_login_noop
    assert_nil @b.login_with_token(username: 'u', token: 't')
    refute @b.authenticated?
  end

  def test_logout_noop
    assert_nil @b.logout
  end
end
