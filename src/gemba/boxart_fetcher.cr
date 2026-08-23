require "http/client"

module Gemba
  # Fetches and caches box art images for ROMs. Ported from ruby gemba's
  # own lib/gemba/boxart_fetcher.rb, with three real changes rather than
  # a literal port - see #fetch, #write_atomically, and #download for
  # why each one is there.
  #
  # Cache layout (same as ruby): {cache_dir}/{game_code}/boxart.png
  #
  # Usage:
  #   fetcher = BoxartFetcher.new(app: app, cache_dir: Paths.boxart_dir, backend: backend)
  #   fetcher.fetch("AGB-BPEE") { |path| update_card_image(path) }
  class BoxartFetcher
    # Resolves a game_code to a download URL, or nil if no art is known
    # to exist for it - pluggable so BoxartFetcher itself never has an
    # opinion on WHERE art comes from. See boxart_fetcher/libretro_backend.cr
    # (the real one) and boxart_fetcher/null_backend.cr (tests/offline
    # mode) - mirrors ruby's own two backends exactly.
    abstract class Backend
      abstract def url_for(game_code : String) : String?
    end

    # Bounds how many downloads run at once, on their OWN isolated
    # threads (see #fetch) - ruby's own version fires one OS thread per
    # in-flight fetch with no cap at all, up to 16 simultaneous
    # downloads for a full 4x4 picker grid.
    MAX_CONCURRENT_FETCHES = 2

    getter cache_dir : String

    def initialize(@app : Tryst::App, @cache_dir : String, @backend : Backend)
      @in_flight = Set(String).new
      @fetch_slots = Channel(Nil).new(MAX_CONCURRENT_FETCHES)
      MAX_CONCURRENT_FETCHES.times { @fetch_slots.send(nil) }

      # Created once, here, before any fetch thread exists - so every
      # #fetch afterward only ever creates its OWN never-shared
      # {cache_dir}/{game_code} leaf directory. Two concurrent fetches
      # both trying to create cache_dir itself (a directory neither of
      # them owns alone) is a real mkdir race, not a hot-path concern -
      # avoiding it once here beats handling it every time it happens.
      Dir.mkdir_p(@cache_dir)
    end

    # Fetch box art for a game code - returns immediately, never blocks
    # the caller. The callback fires later, on a spawned fiber (safe to
    # touch Tk/widget state from directly, same as any plain `spawn`
    # fiber - see examples/fiber_io_demo.cr) - almost immediately if the
    # art is already cached (positively or negatively, see
    # #negative_cached?), or once a real download completes otherwise.
    #
    # Every filesystem/network touch below happens inside
    # App#off_thread(new_thread: true) - its OWN isolated thread, not
    # the single shared queue every OTHER off_thread call in this app
    # funnels through (RomLibrary#remember, Config#save!, ...) - so a
    # slow CDN round-trip can never queue behind, or block, unrelated
    # local disk I/O elsewhere in the app. @fetch_slots bounds how many
    # of those isolated threads can be alive at once (see
    # MAX_CONCURRENT_FETCHES).
    def fetch(game_code : String, &on_fetched : String -> Nil) : Nil
      return if @in_flight.includes?(game_code)
      @in_flight << game_code

      spawn do
        @fetch_slots.receive
        path = begin
          @app.off_thread(new_thread: true) { resolve(game_code) }
        ensure
          @fetch_slots.send(nil)
        end
        @in_flight.delete(game_code)
        on_fetched.call(path) if path
      end
    end

    # @return path where box art would be cached for this game code -
    # pure string join, no I/O, safe to call from anywhere.
    def cached_path(game_code : String) : String
      File.join(@cache_dir, game_code, "boxart.png")
    end

    # @return whether box art is already cached. Real File I/O - call
    # through #off_thread like every other blocking call in this app.
    def cached?(game_code : String) : Bool
      File.exists?(cached_path(game_code))
    end

    private def negative_cache_path(game_code : String) : String
      File.join(@cache_dir, game_code, "boxart.none")
    end

    private def negative_cached?(game_code : String) : Bool
      File.exists?(negative_cache_path(game_code))
    end

    private def resolve(game_code : String) : String?
      cached = cached_path(game_code)
      return cached if File.exists?(cached)
      return if negative_cached?(game_code)

      url = @backend.url_for(game_code)
      return unless url

      download(url, game_code)
    end

    # A 404 (libretro definitively has no art for this game) writes a
    # negative-cache marker so #fetch never asks again - ruby's own
    # version has no such marker, so it re-requests a game with no
    # official art from the CDN every single time its card is drawn.
    # Anything else (a network error, an unexpected status, a
    # suspiciously empty body) is treated as transient and left
    # uncached, so the next #fetch retries it rather than wrongly
    # concluding "will never exist" from what might just be a dropped
    # connection.
    private def download(url : String, game_code : String) : String?
      response = HTTP::Client.get(url)

      if response.status.success? && response.body.bytesize > 0
        dest = cached_path(game_code)
        write_atomically(dest, response.body.to_slice)
        dest
      elsif response.status_code == 404
        write_negative_cache(game_code)
        nil
      end
    rescue ex : Exception
      STDERR.puts "[Gemba] BoxartFetcher: fetch failed for #{game_code}: #{ex.message}"
      nil
    end

    # Downloads to a sibling temp file and renames it into place, rather
    # than writing the final path directly - ruby's own File.binwrite
    # writes straight to the final path, which leaves a corrupt file
    # sitting at #cached_path (and so treated as "cached" forever after)
    # if the process dies or the connection drops mid-write. A rename
    # is atomic on the same filesystem, so #cached_path only ever sees
    # a complete file or none at all.
    private def write_atomically(dest : String, bytes : Bytes) : Nil
      Dir.mkdir_p(File.dirname(dest))
      tmp = "#{dest}.tmp"
      File.write(tmp, bytes)
      File.rename(tmp, dest)
    end

    private def write_negative_cache(game_code : String) : Nil
      path = negative_cache_path(game_code)
      Dir.mkdir_p(File.dirname(path))
      File.write(path, "")
    end
  end
end
