require "http/client"
require "json"
require "../../session_logger"
require "../achievement"

module Gemba
  module Achievements
    module RetroAchievements
      # Every request runs on its own OS thread via App#off_thread, then
      # calls back on the current fiber - safe to touch Tk/Config from,
      # same pattern as BoxartFetcher#fetch.
      class Backend
        RA_HOST    = "retroachievements.org"
        RA_PATH    = "/dorequest.php"
        USER_AGENT = "gemba-crystal/0.1.0 (https://github.com/jamescook/gemba)"

        # requester: swappable for a synchronous fake in specs, same
        # reason ruby's own Backend takes one - the default performs the
        # real HTTPS POST.
        def initialize(@app : Tryst::App, @requester : Proc(Hash(String, String), {JSON::Any?, Bool}) = ->(params : Hash(String, String)) { Backend.post(params) })
        end

        # on_done gets (token, error) - token is set on success, error is
        # a human-readable message on failure.
        def login_with_password(username : String, password : String, &on_done : String?, String? -> Nil) : Nil
          ra_request({"r" => "login2", "u" => username, "p" => password}) do |json, success|
            if json && success && json["Success"]?.try(&.as_bool?)
              on_done.call(json["Token"].as_s, nil)
            else
              on_done.call(nil, error_message(json, success))
            end
          end
        end

        # on_done gets (success, error) - used both to verify a
        # freshly-entered token and as the Verify Token button's ping.
        def verify_token(username : String, token : String, &on_done : Bool, String? -> Nil) : Nil
          ra_request({"r" => "login2", "u" => username, "t" => token}) do |json, request_ok|
            success = json && request_ok && json["Success"]?.try(&.as_bool?)
            on_done.call(!!success, success ? nil : error_message(json, request_ok))
          end
        end

        # Resolves a ROM's MD5 to a RetroAchievements game id. on_done
        # gets nil when the request fails OR when the hash is simply
        # unrecognised (the server answers 0) - neither is an error
        # worth surfacing, it just means no achievements for this ROM.
        def lookup_game_id(md5 : String, &on_done : Int64? -> Nil) : Nil
          ra_request({"r" => "gameid", "m" => md5}) do |json, request_ok|
            game_id = json.try(&.["GameID"]?.try(&.as_i64?)) if request_ok
            on_done.call(game_id.try { |id| id > 0 ? id : nil })
          end
        end

        # What r=patch hands back for one game: the achievement
        # definitions (already filtered, see Achievement.from_patch) and
        # the Rich Presence script, nil when the game has none.
        record Patch, achievements : Array(Achievement), script : String?

        # r=patch - the achievement definitions and presence script for a
        # game. on_done gets nil when the request fails; a game with no
        # achievements and no script is a Patch with an empty list and a
        # nil script, which is a perfectly good answer.
        #
        # Does NOT activate anything: the runtime only learns about
        # achievements once #fetch_unlocks has said which are already
        # earned, so nothing can be awarded in the window between the
        # two replies. Same ordering as ruby gemba's fetch_patch_data
        # -> fetch_unlocks -> activate.
        def fetch_patch(username : String, token : String, game_id : Int64, include_unofficial : Bool = false,
                        &on_done : Patch? -> Nil) : Nil
          ra_request({"r" => "patch", "u" => username, "t" => token, "g" => game_id.to_s}) do |json, request_ok|
            data = json.try(&.["PatchData"]?) if request_ok
            unless data
              on_done.call(nil)
              next
            end

            achievements = Achievement.from_patch(data["Achievements"]?, include_unofficial)
            script = data["RichPresencePatch"]?.try(&.as_s?).presence
            on_done.call(Patch.new(achievements, script))
          end
        end

        # r=unlocks with h=0 (softcore - gemba has no hardcore mode) -
        # the ids the player has already earned for this game, so they
        # are never activated or awarded again. on_done gets nil when
        # the request fails or the server says Success=false; a caller
        # must then NOT activate anything, since it cannot tell a fresh
        # game from one already fully earned.
        def fetch_unlocks(username : String, token : String, game_id : Int64,
                          &on_done : Set(UInt32)? -> Nil) : Nil
          ra_request({"r" => "unlocks", "u" => username, "t" => token, "g" => game_id.to_s, "h" => "0"}) do |json, request_ok|
            unless json && request_ok && json["Success"]?.try(&.as_bool?)
              on_done.call(nil)
              next
            end

            ids = Set(UInt32).new
            json["UserUnlocks"]?.try(&.as_a?).try &.each do |value|
              id = value.as_i64? || value.as_s?.try(&.to_i64?)
              ids << id.to_u32 if id && id > 0
            end
            on_done.call(ids)
          end
        end

        # r=awardachievement - tells the site the player just earned
        # achievement `id`. on_done gets whether the server accepted it
        # (Success=true); anything else - a refusal, an HTTP failure, no
        # network - is false, so the caller can decide what to do about
        # an unlock the site never recorded. Both outcomes reach the
        # log: an unconfirmed unlock is exactly the thing a user will
        # come asking about later.
        def award_achievement(username : String, token : String, id : UInt32, hardcore : Bool = false,
                              &on_done : Bool -> Nil) : Nil
          ra_request({"r" => "awardachievement", "u" => username, "t" => token,
                      "a" => id.to_s, "h" => hardcore ? "1" : "0"}) do |json, request_ok|
            success = !!(json && request_ok && json["Success"]?.try(&.as_bool?))
            if success
              Gemba.log { "RA: submitted unlock for achievement #{id}" }
            else
              Gemba.log(SessionLogger::Level::Warn) do
                "RA: unlock submission failed for achievement #{id}: #{error_message(json, request_ok)}"
              end
            end
            on_done.call(success)
          end
        end

        # The heartbeat that makes the site show "playing <game>" - the
        # current presence string rides along as m=.
        def ping(username : String, token : String, game_id : Int64, message : String,
                 &on_done : Bool -> Nil) : Nil
          ra_request({"r" => "ping", "u" => username, "t" => token,
                      "g" => game_id.to_s, "m" => message}) do |json, request_ok|
            on_done.call(!!(json && request_ok && json["Success"]?.try(&.as_bool?)))
          end
        end

        private def error_message(json : JSON::Any?, request_ok : Bool) : String
          return "Could not connect to RetroAchievements" unless request_ok
          json.try(&.["Error"]?.try(&.as_s?)) || "Request failed"
        end

        private def ra_request(params : Hash(String, String), &on_done : JSON::Any?, Bool -> Nil) : Nil
          spawn do
            Gemba.log { "RA request: #{Backend.redact(params)}" }
            json, request_ok = @app.off_thread(new_thread: true) { @requester.call(params) }
            Gemba.log { "RA response: r=#{params["r"]?} ok=#{request_ok} success=#{json.try(&.["Success"]?)}" }
            on_done.call(json, request_ok)
          end
        end

        # p (password) and t (token) are credentials - they must never
        # reach a log file a user might paste into a bug report.
        def self.redact(params : Hash(String, String)) : String
          params.map { |key, value| "#{key}=#{key.in?("p", "t") ? "[redacted]" : value}" }.join(" ")
        end

        def self.post(params : Hash(String, String)) : {JSON::Any?, Bool}
          response = HTTP::Client.post("https://#{RA_HOST}#{RA_PATH}",
            headers: HTTP::Headers{"User-Agent" => USER_AGENT},
            form: params)
          Gemba.log { "RA http: r=#{params["r"]?} status=#{response.status.code}" }
          response.status.success? ? {JSON.parse(response.body), true} : {nil, false}
        rescue ex : Exception
          Gemba.log(SessionLogger::Level::Error) { "RA request error (r=#{params["r"]?}): #{ex.message}" }
          {nil, false}
        end
      end
    end
  end
end
