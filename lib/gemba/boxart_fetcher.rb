# frozen_string_literal: true

require "net/http"
require "fileutils"

module Gemba
  # Fetches and caches box art images for ROMs.
  #
  # Delegates URL resolution to a pluggable backend (anything responding to
  # +#url_for(game_code)+). Downloads happen off the main thread via
  # +Teek::BackgroundWork+ so the UI stays responsive.
  #
  # Cache layout:
  #   {cache_dir}/{game_code}/boxart.png
  #
  # Usage:
  #   fetcher = BoxartFetcher.new(app: app, cache_dir: Config.boxart_dir, backend: backend)
  #   fetcher.fetch("AGB-BPEE") { |path| update_card_image(path) }
  #
  class BoxartFetcher
    attr_reader :cache_dir

    def initialize(app:, cache_dir:, backend:)
      @app = app
      @cache_dir = cache_dir
      @backend = backend
      @in_flight = {} # game_code => true, prevents duplicate fetches
    end

    # Fetch box art for a game code. If cached, yields the path immediately.
    # Otherwise kicks off an async download and yields the path on completion.
    #
    # @param game_code [String] e.g. "AGB-BPEE"
    # @yield [path] called on the main thread with the cached file path
    # @yieldparam path [String] absolute path to the cached PNG
    def fetch(game_code, &on_fetched)
      return unless on_fetched

      cached = cached_path(game_code)
      if File.exist?(cached)
        on_fetched.call(cached)
        return
      end

      url = @backend.url_for(game_code)
      return unless url
      return if @in_flight[game_code]

      @in_flight[game_code] = true

      Teek::BackgroundWork.new(@app, { url: url, dest: cached, game_code: game_code }, mode: :thread) do |t, data|
        uri = URI(data[:url])
        response = Net::HTTP.get_response(uri)
        if response.is_a?(Net::HTTPSuccess)
          FileUtils.mkdir_p(File.dirname(data[:dest]))
          File.binwrite(data[:dest], response.body)
          t.yield(data[:dest])
        else
          t.yield(nil)
        end
      end.on_progress do |path|
        @in_flight.delete(game_code)
        on_fetched.call(path) if path
      end.on_done do
        @in_flight.delete(game_code)
      end
    end

    # @return [String] path where box art would be cached for this game code
    def cached_path(game_code)
      File.join(@cache_dir, game_code, "boxart.png")
    end

    # @return [Boolean] whether box art is already cached
    def cached?(game_code)
      File.exist?(cached_path(game_code))
    end
  end
end
