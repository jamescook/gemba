require "http/client"
require "json"
require "../../session_logger"

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

        # Achievement data comes back in the same response, but nothing
        # here reads it yet.
        def fetch_rich_presence_script(username : String, token : String, game_id : Int64,
                                       &on_done : String? -> Nil) : Nil
          ra_request({"r" => "patch", "u" => username, "t" => token, "g" => game_id.to_s}) do |json, request_ok|
            script = json.try(&.["PatchData"]?.try(&.["RichPresencePatch"]?.try(&.as_s?))) if request_ok
            on_done.call(script.presence)
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
          json.try(&.["Error"]?.try(&.as_s?)) || "Login failed"
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
