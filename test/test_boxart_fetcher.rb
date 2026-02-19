# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"
require "tmpdir"
require "fileutils"
require "gemba/boxart_fetcher"
require "gemba/boxart/null_backend"

class TestBoxartFetcher < Minitest::Test
  include TeekTestHelper

  FAKE_PNG = "\x89PNG\r\n\x1a\n fake image data".b

  # Minimal backend that returns a fixed URL for known codes
  class StubBackend
    def url_for(game_code)
      case game_code
      when "AGB-AXVE"
        "https://example.com/boxart/pokemon_ruby.png"
      when "AGB-BPEE"
        "https://example.com/boxart/pokemon_emerald.png"
      else
        nil
      end
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("boxart_test")
    @backend = StubBackend.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_cached_path
    fetcher = Gemba::BoxartFetcher.new(app: nil, cache_dir: @tmpdir, backend: @backend)
    expected = File.join(@tmpdir, "AGB-AXVE", "boxart.png")
    assert_equal expected, fetcher.cached_path("AGB-AXVE")
  end

  def test_cached_returns_false_when_not_cached
    fetcher = Gemba::BoxartFetcher.new(app: nil, cache_dir: @tmpdir, backend: @backend)
    refute fetcher.cached?("AGB-AXVE")
  end

  def test_cached_returns_true_when_file_exists
    dir = File.join(@tmpdir, "AGB-AXVE")
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "boxart.png"), FAKE_PNG)

    fetcher = Gemba::BoxartFetcher.new(app: nil, cache_dir: @tmpdir, backend: @backend)
    assert fetcher.cached?("AGB-AXVE")
  end

  def test_fetch_returns_cached_path_immediately_when_cached
    dir = File.join(@tmpdir, "AGB-AXVE")
    FileUtils.mkdir_p(dir)
    cached = File.join(dir, "boxart.png")
    File.binwrite(cached, FAKE_PNG)

    fetcher = Gemba::BoxartFetcher.new(app: nil, cache_dir: @tmpdir, backend: @backend)
    result = nil
    fetcher.fetch("AGB-AXVE") { |path| result = path }

    assert_equal cached, result
  end

  def test_fetch_does_nothing_for_unknown_game_code
    fetcher = Gemba::BoxartFetcher.new(app: nil, cache_dir: @tmpdir, backend: @backend)
    called = false
    fetcher.fetch("AGB-ZZZZ") { |_| called = true }
    refute called
  end

  def test_fetch_does_nothing_with_null_backend
    null_fetcher = Gemba::BoxartFetcher.new(
      app: nil, cache_dir: @tmpdir,
      backend: Gemba::BoxartFetcher::NullBackend.new
    )
    called = false
    null_fetcher.fetch("AGB-AXVE") { |_| called = true }
    refute called
  end

  def test_fetch_does_nothing_without_block
    fetcher = Gemba::BoxartFetcher.new(app: nil, cache_dir: @tmpdir, backend: @backend)
    fetcher.fetch("AGB-AXVE")
  end

  def test_fetch_downloads_and_caches
    assert_tk_app("boxart fetch downloads and caches") do
      require "tmpdir"
      require "webmock"
      require "gemba/boxart_fetcher"
      WebMock.enable!
      WebMock.stub_request(:get, "https://example.com/boxart/pokemon_ruby.png")
        .to_return(status: 200, body: "\x89PNG fake".b, headers: { "Content-Type" => "image/png" })

      tmpdir = Dir.mktmpdir("boxart_test")
      backend = Struct.new(:url) { def url_for(_) = url }.new("https://example.com/boxart/pokemon_ruby.png")
      fetcher = Gemba::BoxartFetcher.new(app: app, cache_dir: tmpdir, backend: backend)
      result = nil
      done = false

      fetcher.fetch("AGB-AXVE") do |path|
        result = path
        done = true
      end

      wait_until(timeout: 5.0) { done }

      assert done, "Fetch did not complete"
      assert_equal fetcher.cached_path("AGB-AXVE"), result
      assert File.exist?(result), "Cached file should exist"
      assert fetcher.cached?("AGB-AXVE")

      FileUtils.rm_rf(tmpdir)
      WebMock.disable!
    end
  end

  def test_fetch_handles_404
    assert_tk_app("boxart fetch handles 404 gracefully") do
      require "tmpdir"
      require "webmock"
      require "gemba/boxart_fetcher"
      WebMock.enable!
      WebMock.stub_request(:get, "https://example.com/boxart/pokemon_ruby.png")
        .to_return(status: 404, body: "Not Found")

      tmpdir = Dir.mktmpdir("boxart_test")
      backend = Struct.new(:url) { def url_for(_) = url }.new("https://example.com/boxart/pokemon_ruby.png")
      fetcher = Gemba::BoxartFetcher.new(app: app, cache_dir: tmpdir, backend: backend)
      called = false

      fetcher.fetch("AGB-AXVE") { |_| called = true }

      wait_until(timeout: 2.0) { false }  # let background thread finish

      refute called, "Callback should not fire on 404"
      refute fetcher.cached?("AGB-AXVE")

      FileUtils.rm_rf(tmpdir)
      WebMock.disable!
    end
  end
end
