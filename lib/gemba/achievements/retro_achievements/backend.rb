# frozen_string_literal: true

require "net/http"
require "json"
require "digest"

module Gemba
  module Achievements
    module RetroAchievements
      # Achievement backend that talks to retroachievements.org.
      #
      # All requests are HTTP POSTs to /dorequest.php.  The 'r' parameter tells
      # the server what you want — it's RA's own naming, not ours:
      #
      #   r=login2   authenticate (password or token)
      #   r=gameid   "here's a ROM MD5 hash — what game ID is it?"
      #   r=patch    "give me the achievement definitions for this game"
      #              (called 'patch' because RA's original concept was that
      #              achievements are a 'patch' bolted on top of a ROM —
      #              extra behaviour injected into the game.  the name stuck.)
      #   r=unlocks  "which of these achievements has the player already earned?"
      #   r=awardachievement  "the player just earned this achievement, record it"
      #
      # Most HTTP is done off the main thread via Teek::BackgroundWork (thread mode).
      # The ping heartbeat uses PING_BG_MODE which selects ractor mode on Ruby 4+.
      #
      # Authentication flow:
      #   login_with_password  → r=login2 + password → stores token, fires :ok
      #   login_with_token     → r=login2 + token    → verifies token, fires :ok/:error
      #   token_test           → same as login_with_token using stored creds
      #
      # Game load flow (all requests are chained — each fires when the previous
      # HTTP response comes back):
      #
      #   load_game(core, rom_path)
      #     → MD5 hash the ROM file
      #     → r=gameid (MD5)          — server tells us the RA game ID
      #     → r=patch  (game ID)      — server sends achievement definitions
      #     → r=unlocks (game ID)     — server says which the player already has
      #     → activate each un-earned achievement in the C runtime
      #       (parse conditions, load into hash table so do_frame checks them)
      #
      # Achievements are not loaded into the runtime until AFTER the unlocks
      # response arrives.  This means @achievements stays empty during the
      # network round-trips, and do_frame's early-return guard prevents any
      # evaluation before we know what the player has already earned.
      class Backend
        include Achievements::Backend

        RA_HOST      = "retroachievements.org"
        RA_PATH      = "/dorequest.php"
        PING_BG_MODE = (RUBY_VERSION >= "4.0" ? :ractor : :thread).freeze

        # Frames between Rich Presence evaluations (~4 s at 60 fps).
        RP_EVAL_INTERVAL  = 240
        # Seconds between session ping heartbeats.
        PING_INTERVAL_SEC = 120

        # Default requester: delegates to Teek::BackgroundWork.
        # Extracted so tests can inject a synchronous fake with the same interface.
        DEFAULT_REQUESTER = lambda do |app, params, mode: :thread, **opts, &block|
          Teek::BackgroundWork.new(app, params, mode: mode, **opts, &block)
        end.freeze

        def initialize(app:, runtime: nil, requester: nil)
          @app              = app
          @requester        = requester || DEFAULT_REQUESTER
          @username         = nil
          @token            = nil
          @game_id          = nil
          @achievements     = []
          @earned           = {}
          @authenticated    = false
          @include_unofficial    = false
          @rich_presence_enabled = false
          @rich_presence_message = nil
          @rp_eval_frame         = 0
          @ping_last_at          = nil
          @ra_runtime       = runtime || Gemba::RARuntime.new
        end

        attr_writer :include_unofficial
        attr_writer :rich_presence_enabled
        attr_reader :rich_presence_message

        # -- Authentication -------------------------------------------------------

        def login_with_password(username:, password:)
          ra_request(r: "login2", u: username, p: password) do |json, ok|
            if ok && json&.dig("Success")
              @username      = username
              @token         = json["Token"]
              @authenticated = true
              Gemba.log(:info) { "RA: authenticated as #{username}" }
              fire_auth_change(:ok, @token)
            else
              msg = json&.dig("Error") || "Login failed"
              Gemba.log(:warn) { "RA: authentication failed for #{username}: #{msg}" }
              fire_auth_change(:error, msg)
            end
          end
        end

        def login_with_token(username:, token:)
          @username = username
          @token    = token
          ra_request(r: "login2", u: username, t: token) do |json, ok|
            if ok && json&.dig("Success")
              @authenticated = true
              Gemba.log(:info) { "RA: token verified for #{username}" }
              fire_auth_change(:ok, nil)
            else
              @authenticated = false
              msg = json&.dig("Error") || "Token invalid"
              Gemba.log(:warn) { "RA: token verification failed for #{username}: #{msg}" }
              fire_auth_change(:error, msg)
            end
          end
        end

        def token_test
          ra_request(r: "login2", u: @username, t: @token) do |json, ok|
            if ok && json&.dig("Success")
              fire_auth_change(:ok, nil)
            else
              @authenticated = false
              fire_auth_change(:error, json&.dig("Error") || "Token invalid")
            end
          end
        end

        def logout
          @username      = nil
          @token         = nil
          @authenticated = false
          @game_id       = nil
          @achievements  = []
          @earned        = {}
          @ra_runtime.clear
          fire_auth_change(:logout)
        end

        def authenticated? = @authenticated
        def enabled?       = true

        # -- Game lifecycle -------------------------------------------------------

        def load_game(core, rom_path = nil, md5 = nil)
          return unless @authenticated
          return unless rom_path && File.exist?(rom_path.to_s)

          @achievements          = []
          @earned                = {}
          @game_id               = nil
          @rich_presence_message = nil
          @rp_eval_frame         = 0
          @ping_last_at          = nil

          # Use pre-computed digest if available (computed at ROM load time and
          # cached in rom_library.json); fall back to computing it here for entries
          # that pre-date MD5 storage.
          md5 ||= Digest::MD5.file(rom_path).hexdigest

          ra_request(r: "gameid", m: md5) do |json, ok|
            next unless ok
            game_id = json&.dig("GameID")&.to_i
            next if !game_id || game_id == 0

            @game_id = game_id
            fetch_patch_data(game_id)
          end
        end

        # Called after a save state is loaded.  Memory just jumped to an arbitrary
        # saved state, so every achievement must go back through the priming and
        # waiting startup sequence — otherwise achievements that were already active
        # fire instantly if the saved memory happens to satisfy their conditions.
        def reset_runtime
          @ra_runtime.reset_all
        end

        def unload_game
          @game_id               = nil
          @achievements          = []
          @earned                = {}
          @rich_presence_message = nil
          @rp_eval_frame         = 0
          @ping_last_at          = nil
          @ra_runtime.clear
          fire_achievements_changed
        end

        def sync_unlocks
          return unless @authenticated
          Gemba.bus.emit(:ra_sync_started)
          unless @game_id
            Gemba.bus.emit(:ra_sync_done, ok: false, reason: :no_game)
            return
          end
          @earned       = {}
          @achievements = []
          @ra_runtime.reset_all
          fetch_patch_data(@game_id, emit_sync_done: true)
        end

        def do_frame(core)
          return if @achievements.empty?

          triggered_ids = @ra_runtime.do_frame(core)
          triggered_ids.each do |id|
            next if @earned.key?(id)
            ach = @achievements.find { |a| a.id == id }
            next unless ach

            earned = ach.earn
            @earned[id] = earned
            fire_unlock(earned)
            submit_unlock(id)
          end

          return unless @rich_presence_enabled

          @rp_eval_frame = (@rp_eval_frame + 1) % RP_EVAL_INTERVAL
          return unless @rp_eval_frame == 0

          msg = @ra_runtime.get_richpresence(core)
          if msg && msg != @rich_presence_message
            @rich_presence_message = msg
            fire_rich_presence_changed(msg)
          end

          now = Time.now
          if @game_id && @authenticated && (@ping_last_at.nil? || now - @ping_last_at >= PING_INTERVAL_SEC)
            @ping_last_at = now
            ping_game_session
          end
        end

        # -- Achievement list -----------------------------------------------------

        def achievement_list
          @achievements.map { |a| @earned[a.id] || a }
        end

        # Fetch the full achievement list for any ROM by its RomInfo, purely for
        # display. Does not touch the live game state (@achievements, @earned,
        # @ra_runtime). Calls the block on the main thread with Array<Achievement>
        # on success or nil on failure.
        #
        # Request chain (all POST to /dorequest.php):
        #   r=gameid m=<md5>
        #   r=patch  u= t= g=<game_id>
        #   r=unlocks u= t= g=<game_id> h=0
        def fetch_for_display(rom_info:, &callback)
          return unless @authenticated && rom_info.md5

          Gemba.log(:info) { "RA fetch_for_display: gameid lookup md5=#{rom_info.md5[0, 8]}… (#{rom_info.title})" }

          ra_request(r: "gameid", m: rom_info.md5) do |json, ok|
            game_id = ok ? json&.dig("GameID")&.to_i : nil
            Gemba.log(game_id&.positive? ? :info : :warn) {
              "RA fetch_for_display: gameid → #{game_id.inspect} ok=#{ok}"
            }
            unless game_id && game_id > 0
              callback.call(nil)
              next
            end

            ra_request(r: "patch", u: @username, t: @token, g: game_id) do |patch_json, patch_ok|
              Gemba.log(patch_ok ? :info : :warn) {
                "RA fetch_for_display: patch g=#{game_id} ok=#{patch_ok} achievements=#{patch_json&.dig("PatchData", "Achievements")&.size.inspect}"
              }
              unless patch_ok && patch_json
                callback.call(nil)
                next
              end

              achievements = (patch_json.dig("PatchData", "Achievements") || []).filter_map do |a|
                next if a["MemAddr"].to_s.empty?
                next if a["Flags"].to_i != 3 && !(a["Flags"].to_i == 5 && @include_unofficial)
                next if a["ID"].to_i > 100_000_000  # skip RA-injected system messages
                Achievement.new(
                  id:          a["ID"].to_s,
                  title:       a["Title"].to_s,
                  description: a["Description"].to_s,
                  points:      a["Points"].to_i,
                  earned_at:   nil,
                )
              end

              ra_request(r: "unlocks", u: @username, t: @token, g: game_id, h: 0) do |ul_json, ul_ok|
                earned_ids = ul_ok && ul_json&.dig("Success") ?
                  (ul_json.dig("UserUnlocks") || []).map(&:to_s) : []
                Gemba.log(ul_ok ? :info : :warn) {
                  "RA fetch_for_display: unlocks g=#{game_id} ok=#{ul_ok} earned=#{earned_ids.size} total=#{achievements.size}"
                }
                result = achievements.map { |a| earned_ids.include?(a.id) ? a.earn : a }
                callback.call(result)
              end
            end
          end
        end

        private

        # Fetch patch data (achievement definitions). Does NOT activate the runtime
        # or populate @achievements — that happens only after unlocks are known,
        # in activate_from_patch. This ensures do_frame can never evaluate and
        # award achievements during the window between patch data and unlocks.
        def fetch_patch_data(game_id, emit_sync_done: false)
          ra_request(r: "patch", u: @username, t: @token, g: game_id) do |json, ok|
            unless ok && json
              Gemba.log(:warn) { "RA: failed to fetch patch data for game #{game_id}" }
              Gemba.bus.emit(:ra_sync_done, ok: false) if emit_sync_done
              next
            end

            rp_script = json.dig("PatchData", "RichPresencePatch").to_s

            raw = (json.dig("PatchData", "Achievements") || []).select do |a|
              !a["MemAddr"].to_s.empty? &&
                (a["Flags"].to_i == 3 || (a["Flags"].to_i == 5 && @include_unofficial)) &&
                a["ID"].to_i <= 100_000_000
            end

            fetch_unlocks(game_id, raw_ach_data: raw, rp_script: rp_script, emit_sync_done: emit_sync_done)
          end
        end

        # Fetch already-earned achievement IDs, then activate the runtime with
        # all achievements, immediately deactivating the already-earned ones.
        # Only after this step is @achievements populated — so do_frame's
        # `return if @achievements.empty?` guard covers the entire window.
        def fetch_unlocks(game_id, raw_ach_data: nil, rp_script: nil, emit_sync_done: false)
          ra_request(r: "unlocks", u: @username, t: @token, g: game_id, h: 0) do |json, ok|
            unless ok && json&.dig("Success")
              Gemba.log(:warn) { "RA: failed to fetch unlocks for game #{game_id}" }
              Gemba.bus.emit(:ra_sync_done, ok: false) if emit_sync_done
              next
            end

            earned_ids = (json.dig("UserUnlocks") || []).map(&:to_s)

            if raw_ach_data
              # Fresh load / re-sync: activate runtime now that we know earned set.
              @ra_runtime.clear
              @achievements = raw_ach_data.filter_map do |a|
                id      = a["ID"].to_s
                memaddr = a["MemAddr"].to_s
                begin
                  @ra_runtime.activate(id, memaddr)
                rescue ArgumentError => e
                  Gemba.log(:warn) { "RA: skipping achievement #{id} — #{e.message}" }
                  next
                end
                @ra_runtime.deactivate(id) if earned_ids.include?(id)
                Achievement.new(
                  id:          id,
                  title:       a["Title"].to_s,
                  description: a["Description"].to_s,
                  points:      a["Points"].to_i,
                  earned_at:   nil,
                )
              end
              Gemba.log(:info) { "RA: loaded #{@achievements.size} achievements for game #{game_id}" }

              if rp_script && !rp_script.empty?
                ok = @ra_runtime.activate_richpresence(rp_script)
                Gemba.log(ok ? :info : :warn) { "RA: rich presence script #{ok ? "activated" : "failed to parse"} for game #{game_id}" }
              end
            end

            newly_marked = 0
            earned_ids.each do |id|
              next if @earned.key?(id)
              ach = @achievements.find { |a| a.id == id }
              next unless ach
              earned = ach.earn
              @earned[id] = earned
              newly_marked += 1
            end

            Gemba.log(:info) { "RA: synced #{newly_marked} pre-earned achievements for game #{game_id}" } if newly_marked > 0
            fire_achievements_changed
            Gemba.bus.emit(:ra_sync_done, ok: true) if emit_sync_done
          end
        end

        # POST r=ping heartbeat — keeps the RA session alive and records
        # the current Rich Presence string on the server.
        # Runs via PingWorker which is Ractor-safe on Ruby 4+.
        def ping_game_session
          data = {
            host:   RA_HOST,
            path:   RA_PATH,
            params: {
              "r" => "ping",
              "u" => @username,
              "t" => @token,
              "g" => @game_id.to_s,
              "m" => @rich_presence_message.to_s,
            },
          }
          data = Ractor.make_shareable(data) if PING_BG_MODE == :ractor
          game_id = @game_id
          @requester.call(@app, data, mode: PING_BG_MODE, worker: PingWorker)
            .on_progress { |ok| Gemba.log(ok ? :info : :warn) { "RA: ping g=#{game_id} ok=#{ok}" } }
        end

        # Best-effort unlock submission — fires and forgets, result only logged.
        def submit_unlock(achievement_id, hardcore: false)
          ra_request(r: "awardachievement", u: @username, t: @token,
                     a: achievement_id, h: hardcore ? 1 : 0) do |json, ok|
            if ok && json&.dig("Success")
              Gemba.log(:info) { "RA: submitted unlock for achievement #{achievement_id}" }
            else
              Gemba.log(:warn) { "RA: unlock submission failed for #{achievement_id}: #{json&.dig("Error")}" }
            end
          end
        end

        # POST to dorequest.php via @requester (BackgroundWork in production,
        # a synchronous fake in tests). Calls on_done with (json_or_nil, ok_bool).
        def ra_request(params, &on_done)
          @requester.call(@app, params, mode: :thread) do |t, req_params|
            uri  = URI::HTTPS.build(host: RA_HOST, path: RA_PATH)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl      = true
            http.read_timeout = 15
            req  = Net::HTTP::Post.new(uri.path)
            safe = req_params.reject { |k, _| [:t, :p, "t", "p"].include?(k) }
            Gemba.log(:info) { "RA request: r=#{params[:r]} #{safe.map { |k, v| "#{k}=#{v}" }.join(" ")}" }
            req.set_form_data(req_params.transform_keys(&:to_s).transform_values(&:to_s))
            resp = http.request(req)
            if resp.is_a?(Net::HTTPSuccess)
              body = resp.body
              Gemba.log(:info) { "RA response: r=#{params[:r]} HTTP #{resp.code} body=#{body.length}b" }
              t.yield([JSON.parse(body), true])
            else
              Gemba.log(:warn) { "RA response: r=#{params[:r]} HTTP #{resp.code} #{resp.message} body=#{resp.body.to_s[0, 200]}" }
              t.yield([nil, false])
            end
          rescue => e
            Gemba.log(:warn) { "RA: request error (#{params[:r]}): #{e.class} #{e.message}" }
            t.yield([nil, false])
          end.on_progress do |result|
            on_done.call(*result) if on_done && result
          end
        end
      end
    end
  end
end
