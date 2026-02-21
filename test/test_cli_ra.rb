# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "gemba/headless"
require "gemba/cli/commands/retro_achievements"
require_relative "support/fake_requester"

# Tests for the `gemba ra` CLI subcommand.
#
# All tests use:
#   - FakeRequester   so no real HTTP calls are made
#   - A temp Config   so real credentials on disk are never read or written
class TestCLIRa < Minitest::Test
  RA = Gemba::CLI::Commands::RetroAchievements

  def setup
    @tmpdir = Dir.mktmpdir("gemba_cli_ra_test")
    @config = Gemba::Config.new(path: File.join(@tmpdir, "settings.json"))
    @req    = FakeRequester.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def run_ra(argv, dry_run: false)
    RA.new(argv, dry_run: dry_run, config: @config, requester: @req).call
  end

  # ---------------------------------------------------------------------------
  # parse / dry_run
  # ---------------------------------------------------------------------------

  def test_parse_login_returns_subcommand_and_username
    result = run_ra(["login", "--username", "bob"], dry_run: true)
    assert_equal :ra_login, result[:command]
    assert_equal :login,    result[:subcommand]
    assert_equal "bob",     result[:username]
  end

  def test_parse_login_captures_password
    result = run_ra(["login", "--username", "bob", "--password", "s3cr3t"], dry_run: true)
    assert_equal "s3cr3t", result[:password]
  end

  def test_parse_verify_returns_subcommand
    result = run_ra(["verify"], dry_run: true)
    assert_equal :ra_verify, result[:command]
  end

  def test_parse_logout_returns_subcommand
    result = run_ra(["logout"], dry_run: true)
    assert_equal :ra_logout, result[:command]
  end

  def test_parse_achievements_captures_rom_and_json
    result = run_ra(["achievements", "--rom", "/tmp/game.gba", "--json"], dry_run: true)
    assert_equal :ra_achievements, result[:command]
    assert_equal File.expand_path("/tmp/game.gba"), result[:rom]
    assert result[:json]
  end

  def test_parse_no_subcommand_returns_help
    result = run_ra([], dry_run: true)
    assert_equal :ra, result[:command]
    assert result[:help]
  end

  def test_parse_unknown_subcommand_returns_help
    result = run_ra(["frobnicate"], dry_run: true)
    assert result[:help]
  end

  # ---------------------------------------------------------------------------
  # ra login
  # ---------------------------------------------------------------------------

  def test_login_success_saves_credentials
    @req.stub(r: "login2", body: { "Success" => true, "Token" => "tok123" })

    out, = capture_io do
      run_ra(["login", "--username", "bob", "--password", "pass"])
    end

    assert_match(/logged in as bob/i, out)
    assert_equal "bob",    @config.ra_username
    assert_equal "tok123", @config.ra_token
    assert @config.ra_enabled?

    # Verify persisted to disk
    reloaded = Gemba::Config.new(path: @config.instance_variable_get(:@path))
    assert_equal "bob",    reloaded.ra_username
    assert_equal "tok123", reloaded.ra_token
  end

  def test_login_failure_prints_error_and_exits
    @req.stub(r: "login2", body: { "Success" => false, "Error" => "Bad password" }, ok: false)

    assert_raises(SystemExit) do
      capture_io { run_ra(["login", "--username", "bob", "--password", "wrong"]) }
    end

    assert_empty @config.ra_username, "credentials must not be saved on failure"
  end

  def test_login_missing_username_exits
    assert_raises(SystemExit) do
      capture_io { run_ra(["login", "--password", "pass"]) }
    end
  end

  def test_login_posts_to_login2
    @req.stub(r: "login2", body: { "Success" => true, "Token" => "t" })
    capture_io { run_ra(["login", "--username", "bob", "--password", "p"]) }
    assert @req.requested?("login2")
    assert_equal "bob", @req.requests_for("login2").first[:u]
  end

  # ---------------------------------------------------------------------------
  # ra verify
  # ---------------------------------------------------------------------------

  def test_verify_success_prints_ok
    @config.ra_username = "bob"
    @config.ra_token    = "tok"
    @req.stub(r: "login2", body: { "Success" => true })

    out, = capture_io { run_ra(["verify"]) }
    assert_match(/token valid for bob/i, out)
  end

  def test_verify_failure_exits
    @config.ra_username = "bob"
    @config.ra_token    = "bad"
    @req.stub(r: "login2", body: { "Success" => false, "Error" => "Token invalid" }, ok: false)

    assert_raises(SystemExit) do
      capture_io { run_ra(["verify"]) }
    end
  end

  def test_verify_not_logged_in_exits
    assert_raises(SystemExit) do
      capture_io { run_ra(["verify"]) }
    end
  end

  # ---------------------------------------------------------------------------
  # ra logout
  # ---------------------------------------------------------------------------

  def test_logout_clears_credentials
    @config.ra_username = "bob"
    @config.ra_token    = "tok"
    @config.ra_enabled  = true
    @config.save!

    out, = capture_io { run_ra(["logout"]) }

    assert_match(/logged out/i, out)
    assert_empty @config.ra_username
    assert_empty @config.ra_token
    refute @config.ra_enabled?

    reloaded = Gemba::Config.new(path: @config.instance_variable_get(:@path))
    assert_empty reloaded.ra_username
    assert_empty reloaded.ra_token
  end

  def test_logout_makes_no_http_requests
    capture_io { run_ra(["logout"]) }
    assert_empty @req.requests
  end
end
