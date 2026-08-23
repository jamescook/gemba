require "../spec_helper"
require "file_utils"
require "http/server"
require "base64"
require "../../src/gemba/boxart_fetcher"

private def with_tempdir(&)
  dir = File.tempname("boxart_fetcher_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# A failed .should skips past a trailing app.destroy, leaking a real
# Tk window - this guarantees destroy runs even on failure.
private def with_app(title : String, &)
  app = Tryst::App.new(title: title)
  begin
    yield app
  ensure
    app.destroy
  end
end

private class FakeBackend < Gemba::BoxartFetcher::Backend
  def initialize(@urls : Hash(String, String) = {} of String => String)
  end

  def url_for(game_code : String) : String?
    @urls[game_code]?
  end
end

# Real PNG bytes so cached files are genuinely checkable, not stubs.
private ONE_PIXEL_PNG = Base64.decode(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)

describe Gemba::BoxartFetcher do
  it "#cached_path is a pure join, no I/O" do
    with_app("boxart_1") do |app|
      fetcher = Gemba::BoxartFetcher.new(app, "/tmp/whatever", FakeBackend.new)
      fetcher.cached_path("AGB-BPEE").should eq "/tmp/whatever/AGB-BPEE/boxart.png"
    end
  end

  it "calls back immediately with the cached path if already cached, without consulting the backend" do
    with_tempdir do |dir|
      cache_dir = File.join(dir, "cache")
      Dir.mkdir_p(File.join(cache_dir, "AGB-BPEE"))
      File.write(File.join(cache_dir, "AGB-BPEE", "boxart.png"), ONE_PIXEL_PNG)

      with_app("boxart_2") do |app|
        backend = FakeBackend.new
        fetcher = Gemba::BoxartFetcher.new(app, cache_dir, backend)

        result = nil
        fetcher.fetch("AGB-BPEE") { |path| result = path }
        app.interp.wait_until(2.seconds) { !result.nil? }

        result.should eq fetcher.cached_path("AGB-BPEE")
      end
    end
  end

  it "never calls back when the backend has no URL for this game_code" do
    with_tempdir do |dir|
      with_app("boxart_3") do |app|
        fetcher = Gemba::BoxartFetcher.new(app, File.join(dir, "cache"), FakeBackend.new)

        called = false
        fetcher.fetch("AGB-UNKNOWN") { |_path| called = true }
        sleep 100.milliseconds
        app.update

        called.should be_false
      end
    end
  end

  it "downloads real bytes, calls back with the cached path, and leaves no temp file behind" do
    server = HTTP::Server.new do |context|
      context.response.status_code = 200
      context.response.content_type = "image/png"
      context.response.write(ONE_PIXEL_PNG)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    sleep 10.milliseconds

    begin
      with_tempdir do |dir|
        cache_dir = File.join(dir, "cache")

        with_app("boxart_4") do |app|
          backend = FakeBackend.new({"AGB-BPEE" => "http://127.0.0.1:#{address.port}/boxart.png"})
          fetcher = Gemba::BoxartFetcher.new(app, cache_dir, backend)

          result = nil
          fetcher.fetch("AGB-BPEE") { |path| result = path }
          app.interp.wait_until(5.seconds) { !result.nil? }

          result.should eq fetcher.cached_path("AGB-BPEE")
          File.read(fetcher.cached_path("AGB-BPEE")).to_slice.should eq ONE_PIXEL_PNG
          File.exists?("#{fetcher.cached_path("AGB-BPEE")}.tmp").should be_false
        end
      end
    ensure
      server.close
    end
  end

  it "a 404 writes a negative-cache marker so a second fetch never hits the server again" do
    request_count = 0
    server = HTTP::Server.new do |context|
      request_count += 1
      context.response.status_code = 404
      context.response.print "not found"
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    sleep 10.milliseconds

    begin
      with_tempdir do |dir|
        with_app("boxart_5") do |app|
          backend = FakeBackend.new({"AGB-NOART" => "http://127.0.0.1:#{address.port}/missing.png"})
          fetcher = Gemba::BoxartFetcher.new(app, File.join(dir, "cache"), backend)

          called = false
          fetcher.fetch("AGB-NOART") { |_path| called = true }
          app.interp.wait_until(5.seconds) { request_count >= 1 }
          sleep 50.milliseconds # let the negative-cache write actually land
          app.update

          called.should be_false

          # Second fetch: no new request should reach the server at all.
          fetcher.fetch("AGB-NOART") { |_path| called = true }
          sleep 100.milliseconds
          app.update

          request_count.should eq 1
          called.should be_false
        end
      end
    ensure
      server.close
    end
  end

  it "a connection failure is NOT negative-cached - a later fetch can still retry" do
    with_tempdir do |dir|
      with_app("boxart_6") do |app|
        # Nothing listens on this port - a real connection failure, not
        # a stubbed one.
        backend = FakeBackend.new({"AGB-FLAKY" => "http://127.0.0.1:1/boxart.png"})
        fetcher = Gemba::BoxartFetcher.new(app, File.join(dir, "cache"), backend)

        called = false
        fetcher.fetch("AGB-FLAKY") { |_path| called = true }
        sleep 300.milliseconds
        app.update

        called.should be_false
        File.exists?(File.join(dir, "cache", "AGB-FLAKY", "boxart.none")).should be_false
      end
    end
  end

  it "de-dupes concurrent fetches for the same game_code - only one request reaches the server" do
    request_count = 0
    server = HTTP::Server.new do |context|
      request_count += 1
      sleep 100.milliseconds
      context.response.status_code = 200
      context.response.write(ONE_PIXEL_PNG)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    sleep 10.milliseconds

    begin
      with_tempdir do |dir|
        with_app("boxart_7") do |app|
          backend = FakeBackend.new({"AGB-DUP" => "http://127.0.0.1:#{address.port}/boxart.png"})
          fetcher = Gemba::BoxartFetcher.new(app, File.join(dir, "cache"), backend)

          results = [] of String
          fetcher.fetch("AGB-DUP") { |path| results << path }
          fetcher.fetch("AGB-DUP") { |path| results << path }
          app.interp.wait_until(5.seconds) { results.size >= 1 }
          sleep 200.milliseconds
          app.update

          request_count.should eq 1
          results.size.should eq 1
        end
      end
    ensure
      server.close
    end
  end

  it "bounds concurrent downloads to MAX_CONCURRENT_FETCHES" do
    active = 0
    max_active = 0
    lock = Mutex.new
    server = HTTP::Server.new do |context|
      lock.synchronize { active += 1; max_active = {active, max_active}.max }
      sleep 150.milliseconds
      lock.synchronize { active -= 1 }
      context.response.status_code = 200
      context.response.write(ONE_PIXEL_PNG)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    sleep 10.milliseconds

    begin
      with_tempdir do |dir|
        with_app("boxart_8") do |app|
          codes = (1..5).map { |i| "AGB-C0#{i}" }
          urls = codes.each_with_object({} of String => String) { |code, hash| hash[code] = "http://127.0.0.1:#{address.port}/#{code}.png" }
          fetcher = Gemba::BoxartFetcher.new(app, File.join(dir, "cache"), FakeBackend.new(urls))

          done_count = 0
          codes.each { |code| fetcher.fetch(code) { |_path| done_count += 1 } }
          finished = app.interp.wait_until(5.seconds) { done_count == codes.size }

          finished.should be_true
          done_count.should eq codes.size
          max_active.should be <= Gemba::BoxartFetcher::MAX_CONCURRENT_FETCHES
        end
      end
    ensure
      server.close
    end
  end
end
