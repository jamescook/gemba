require "json"

module Gemba
  module Achievements
    module RetroAchievements
      # A stand-in for the real retroachievements.org endpoint: answers
      # the same r= request chain (login2/gameid/patch/ping) with canned
      # JSON, with no network involved.
      #
      # Deliberately built on Backend's existing requester seam rather
      # than as a second Backend implementation (ruby gemba's own
      # FakeBackend is a whole parallel class): swapping only the
      # transport keeps every layer above it - response parsing, the
      # callback chain, the ping timer, the settings UI - running the
      # real code, so a bug in any of them still shows up here.
      #
      #     window = Gemba::MainWindow.new(ra_requester: fake.to_proc)
      #
      # Records every request it receives, so a spec (or a person
      # watching a dev instance) can assert on what was actually sent -
      # #ping_messages in particular is the presence strings that would
      # have reached the site.
      class FakeRequester
        getter requests = [] of Hash(String, String)

        # game_id: nil makes gameid lookups report "unrecognised ROM".
        # script: nil makes the game report no Rich Presence script.
        def initialize(@game_id : Int64? = 515_i64,
                       @script : String? = "Display:\nIn Littleroot Town",
                       @valid_username : String? = nil,
                       @valid_token : String? = nil,
                       @offline : Bool = false)
        end

        def to_proc : Proc(Hash(String, String), {JSON::Any?, Bool})
          ->(params : Hash(String, String)) { call(params) }
        end

        # Every m= seen by a ping - the presence strings that would have
        # been published.
        def ping_messages : Array(String)
          @requests.select { |request| request["r"]? == "ping" }.map { |request| request["m"]? || "" }
        end

        def call(params : Hash(String, String)) : {JSON::Any?, Bool}
          @requests << params
          return {nil, false} if @offline

          case params["r"]?
          when "login2" then login_response(params)
          when "gameid" then {JSON.parse({"Success" => true, "GameID" => @game_id || 0}.to_json), true}
          when "patch"  then patch_response
          when "ping"   then {JSON.parse(%({"Success":true})), true}
          else               {JSON.parse(%({"Success":false,"Error":"FakeRequester: unhandled request"})), true}
          end
        end

        private def login_response(params : Hash(String, String)) : {JSON::Any?, Bool}
          credential = params["p"]? || params["t"]?
          username_ok = @valid_username.nil? || params["u"]? == @valid_username
          credential_ok = @valid_token.nil? || credential == @valid_token

          if !params["u"].presence || !credential.presence || !username_ok || !credential_ok
            return {JSON.parse(%({"Success":false,"Error":"Invalid User/Password combination."})), true}
          end

          {JSON.parse({"Success" => true, "Token" => "fake-token-#{params["u"]}"}.to_json), true}
        end

        private def patch_response : {JSON::Any?, Bool}
          {JSON.parse({"Success" => true, "PatchData" => {"RichPresencePatch" => @script || ""}}.to_json), true}
        end
      end
    end
  end
end
