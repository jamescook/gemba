require "http/client"
require "json"

module Gemba
  module Achievements
    module RetroAchievements
      # Talks to retroachievements.org's r=login2 endpoint - the
      # authentication slice of ruby gemba's own RetroAchievements::Backend.
      # Achievement evaluation (rcheevos, do_frame, unlocks, rich presence)
      # isn't ported yet; this class only proves/stores credentials.
      #
      # Every request runs on its own OS thread via App#off_thread, then
      # calls back on the current fiber (safe to touch Tk/Config from) -
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

        private def error_message(json : JSON::Any?, request_ok : Bool) : String
          return "Could not connect to RetroAchievements" unless request_ok
          json.try(&.["Error"]?.try(&.as_s?)) || "Login failed"
        end

        private def ra_request(params : Hash(String, String), &on_done : JSON::Any?, Bool -> Nil) : Nil
          spawn do
            json, request_ok = @app.off_thread(new_thread: true) { @requester.call(params) }
            on_done.call(json, request_ok)
          end
        end

        def self.post(params : Hash(String, String)) : {JSON::Any?, Bool}
          response = HTTP::Client.post("https://#{RA_HOST}#{RA_PATH}",
            headers: HTTP::Headers{"User-Agent" => USER_AGENT},
            form: params)
          response.status.success? ? {JSON.parse(response.body), true} : {nil, false}
        rescue ex : Exception
          STDERR.puts "[Gemba] RetroAchievements: request error (#{params["r"]}): #{ex.message}"
          {nil, false}
        end
      end
    end
  end
end
