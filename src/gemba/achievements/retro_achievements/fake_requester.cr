require "json"

module Gemba
  module Achievements
    module RetroAchievements
      # A stand-in for the real retroachievements.org endpoint: answers
      # the same r= request chain (login2/gameid/patch/unlocks/
      # awardachievement/ping) with canned JSON, with no network
      # involved.
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
      # have reached the site, #awarded_ids the unlocks it would have
      # recorded.
      class FakeRequester
        getter requests = [] of Hash(String, String)

        # Whether r=awardachievement is refused. A property rather than
        # a constructor-only knob so one fake can play out failure-then-
        # success across a session, which is what a retry needs to see.
        property? award_fails : Bool = false

        # Whether r=unlocks fails outright (request error) - the
        # "cannot know what is already earned" case a caller must react
        # to by activating nothing.
        property? unlocks_fail : Bool = false

        # game_id: nil makes gameid lookups report "unrecognised ROM".
        # script: nil makes the game report no Rich Presence script.
        # achievements: the PatchData.Achievements entries, built with
        # .achievement. unlocked: the ids r=unlocks reports as already
        # earned; a successful award adds to it, the way the site would.
        def initialize(@game_id : Int64? = 515_i64,
                       @script : String? = "Display:\nIn Littleroot Town",
                       @valid_username : String? = nil,
                       @valid_token : String? = nil,
                       @offline : Bool = false,
                       @achievements : Array(JSON::Any) = [] of JSON::Any,
                       @unlocked : Array(Int64) = [] of Int64)
        end

        # One PatchData.Achievements entry, shaped the way the site
        # sends it (integer id/points/flags, condition string in
        # MemAddr). flags defaults to a published core achievement.
        def self.achievement(id : Int64, memaddr : String, title : String = "Achievement #{id}",
                             points : Int64 = 5, flags : Int64 = Achievement::CORE.to_i64,
                             description : String = "") : JSON::Any
          JSON.parse({
            "ID" => id, "Title" => title, "Description" => description,
            "Points" => points, "MemAddr" => memaddr, "Flags" => flags,
          }.to_json)
        end

        def to_proc : Proc(Hash(String, String), {JSON::Any?, Bool})
          ->(params : Hash(String, String)) { call(params) }
        end

        # Every m= seen by a ping - the presence strings that would have
        # been published.
        def ping_messages : Array(String)
          @requests.select { |request| request["r"]? == "ping" }.map { |request| request["m"]? || "" }
        end

        # Every a= seen by an awardachievement, refused or not, in the
        # order they arrived.
        def awarded_ids : Array(Int64)
          @requests.select { |request| request["r"]? == "awardachievement" }.compact_map { |request| request["a"]?.try(&.to_i64?) }
        end

        def call(params : Hash(String, String)) : {JSON::Any?, Bool}
          @requests << params
          return {nil, false} if @offline

          case params["r"]?
          when "login2"           then login_response(params)
          when "gameid"           then {JSON.parse({"Success" => true, "GameID" => @game_id || 0}.to_json), true}
          when "patch"            then patch_response
          when "unlocks"          then unlocks_response
          when "awardachievement" then award_response(params)
          when "ping"             then {JSON.parse(%({"Success":true})), true}
          else                         {JSON.parse(%({"Success":false,"Error":"FakeRequester: unhandled request"})), true}
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
          data = {"RichPresencePatch" => @script || "", "Achievements" => @achievements}
          {JSON.parse({"Success" => true, "PatchData" => data}.to_json), true}
        end

        private def unlocks_response : {JSON::Any?, Bool}
          return {nil, false} if @unlocks_fail

          {JSON.parse({"Success" => true, "GameID" => @game_id || 0, "UserUnlocks" => @unlocked}.to_json), true}
        end

        private def award_response(params : Hash(String, String)) : {JSON::Any?, Bool}
          return {JSON.parse(%({"Success":false,"Error":"FakeRequester: award refused"})), true} if @award_fails

          id = params["a"]?.try(&.to_i64?) || 0_i64
          @unlocked << id unless @unlocked.includes?(id)
          {JSON.parse({"Success" => true, "AchievementID" => id, "Score" => 0}.to_json), true}
        end
      end
    end
  end
end
