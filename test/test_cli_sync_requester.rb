# frozen_string_literal: true

require "minitest/autorun"
require "webmock"
require "gemba/headless"

RA_URL = "https://retroachievements.org/dorequest.php" unless defined?(RA_URL)

class TestCLISyncRequester < Minitest::Test
  include WebMock::API

  Requester = Gemba::Achievements::RetroAchievements::CliSyncRequester

  def setup
    WebMock.enable!
    @req = Requester.new
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  def stub_ra(body:, status: 200)
    WebMock.stub_request(:post, RA_URL)
      .to_return(status: status, body: body, headers: { "Content-Type" => "application/json" })
  end

  # -- Result interface -------------------------------------------------------

  def test_result_on_progress_fires_synchronously
    result = Requester::Result.new(["data", true])
    received = nil
    result.on_progress { |v| received = v }
    assert_equal ["data", true], received
  end

  def test_result_on_progress_returns_self_for_chaining
    r = Requester::Result.new(nil)
    assert_same r, r.on_progress {}
  end

  def test_result_on_done_returns_self
    r = Requester::Result.new(nil)
    assert_same r, r.on_done {}
  end

  # -- Successful HTTP call ---------------------------------------------------

  def test_success_returns_parsed_json_and_true
    stub_ra(body: JSON.generate("Success" => true, "Token" => "abc"))

    received = nil
    @req.call(nil, { r: "login2", u: "user", p: "pass" })
      .on_progress { |v| received = v }

    assert_equal true,    received[1]
    assert_equal true,    received[0]["Success"]
    assert_equal "abc",   received[0]["Token"]
  end

  def test_posts_to_correct_url
    stub_ra(body: JSON.generate("Success" => true))

    @req.call(nil, { r: "gameid", m: "deadbeef" })
      .on_progress {}

    assert_requested :post, RA_URL
  end

  def test_sends_params_as_form_data
    stub_ra(body: JSON.generate("GameID" => 42))

    @req.call(nil, { r: "gameid", m: "abc123" })
      .on_progress {}

    assert_requested :post, RA_URL, body: "r=gameid&m=abc123"
  end

  def test_symbol_keys_stringified
    stub_ra(body: JSON.generate("Success" => true))

    @req.call(nil, { r: "ping", u: "user", t: "tok", g: 42, m: "Playing" })
      .on_progress {}

    assert_requested :post, RA_URL,
      body: hash_including("r" => "ping", "u" => "user", "t" => "tok")
  end

  # -- HTTP error responses ---------------------------------------------------

  def test_http_404_returns_nil_false
    stub_ra(body: "Not Found", status: 404)

    received = nil
    @req.call(nil, { r: "gameid", m: "bad" })
      .on_progress { |v| received = v }

    assert_equal [nil, false], received
  end

  def test_http_500_returns_nil_false
    stub_ra(body: "Internal Server Error", status: 500)

    received = nil
    @req.call(nil, { r: "patch", u: "u", t: "t", g: 1 })
      .on_progress { |v| received = v }

    assert_equal [nil, false], received
  end

  # -- Network errors ---------------------------------------------------------

  def test_connection_error_returns_nil_false
    WebMock.stub_request(:post, RA_URL).to_raise(Errno::ECONNREFUSED)

    received = nil
    _, stderr = capture_io do
      @req.call(nil, { r: "login2" }).on_progress { |v| received = v }
    end

    assert_equal [nil, false], received
    assert_match(/request error/i, stderr)
  end

  def test_timeout_returns_nil_false
    WebMock.stub_request(:post, RA_URL).to_raise(Net::ReadTimeout)

    received = nil
    capture_io do
      @req.call(nil, { r: "login2" }).on_progress { |v| received = v }
    end

    assert_equal [nil, false], received
  end

  # -- mode: and worker: kwargs are accepted but ignored ----------------------

  def test_accepts_mode_kwarg
    stub_ra(body: JSON.generate("ok" => true))
    assert_silent do
      @req.call(nil, { r: "ping" }, mode: :ractor).on_progress {}
    end
  end

  def test_accepts_worker_kwarg
    stub_ra(body: JSON.generate("ok" => true))
    assert_silent do
      @req.call(nil, { r: "ping" }, worker: Object.new).on_progress {}
    end
  end
end
