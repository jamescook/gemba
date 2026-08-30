require "option_parser"
require "../config"
require "../paths"
require "../core"
require "../rom_library"
require "../achievements/achievement"
require "../achievements/cache"
require "../achievements/rom_hash"
require "../achievements/retro_achievements/backend"

module Gemba
  module CLI
    # `gemba ra <login|verify|logout|achievements|sync>` - headless
    # RetroAchievements plumbing, ruby's retro_achievements.rb plus a
    # `sync` subcommand this port adds: fetch a ROM's definitions and
    # earned state and write them to the offline achievement cache, so
    # the in-app browser has fresh data for games that aren't loaded.
    #
    # Talks to the same requester seam the app's Backend does (the
    # Proc a spec swaps for FakeRequester) - but synchronously, right
    # on this thread: Backend itself is built around a live Tryst::App
    # for its off-thread hop, and a CLI has no app, no Tk thread to
    # protect, and no reason not to just wait. Response PARSING is
    # shared where it has real shape (Achievement.from_patch); the
    # small Success/ids checks are inlined.
    class Ra
      RA_SUBCOMMANDS = %w[login verify logout achievements sync]

      alias Requester = Proc(Hash(String, String), {JSON::Any?, Bool})

      record Plan,
        subcommand : Symbol? = nil, username : String? = nil, password : String? = nil,
        rom : String? = nil, json : Bool = false, help : Bool = false

      def initialize(@argv : Array(String), @dry_run : Bool = false,
                     @io : IO = STDOUT, @err : IO = STDERR, @input : IO = STDIN,
                     @config_path : String = Config.path,
                     @cache_dir : String = Paths.achievements_cache_dir,
                     @requester : Requester = ->(params : Hash(String, String)) { Achievements::RetroAchievements::Backend.post(params) })
      end

      def call : Plan
        plan = parse

        if plan.help || plan.subcommand.nil?
          @io.puts @parser unless @dry_run
          return plan
        end
        return plan if @dry_run

        case plan.subcommand
        when :login        then login(plan)
        when :verify       then verify
        when :logout       then logout
        when :achievements then achievements(plan)
        when :sync         then sync(plan)
        end
        plan
      end

      private def parse : Plan
        argv = @argv.dup
        sub = RA_SUBCOMMANDS.includes?(argv.first?) ? argv.shift : nil

        username = nil.as(String?)
        password = nil.as(String?)
        rom = nil.as(String?)
        json = false
        help = false
        positionals = [] of String

        parser = OptionParser.new do |opts|
          opts.banner = banner_for(sub)
          case sub
          when "login"
            opts.on("--username USER", "RetroAchievements username") { |value| username = value }
            opts.on("--password PASS", "Password (prompts if omitted)") { |value| password = value }
          when "achievements"
            opts.on("--rom PATH", "Path to the GBA ROM file") { |value| rom = File.expand_path(value) }
            opts.on("--json", "Output as JSON") { json = true }
          end
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.unknown_args { |before_dash, after_dash| positionals = before_dash + after_dash }
          opts.invalid_option do |flag|
            @io.puts "gemba ra: unknown option #{flag}"
            help = true
          end
        end
        @parser = parser
        parser.parse(argv)

        # sync takes its ROM as a positional (`gemba ra sync rom.gba`).
        rom ||= positionals.first?.try { |path| File.expand_path(path) } if sub == "sync"

        Plan.new(subcommand: subcommand_symbol(sub), username: username, password: password,
          rom: rom, json: json, help: help)
      end

      # No runtime String#to_sym in Crystal - symbols are compile-time.
      private def subcommand_symbol(sub : String?) : Symbol?
        case sub
        when "login"        then :login
        when "verify"       then :verify
        when "logout"       then :logout
        when "achievements" then :achievements
        when "sync"         then :sync
        end
      end

      private def banner_for(sub : String?) : String
        case sub
        when "login"        then "Usage: gemba ra login --username USER [--password PASS]\n\nLog in to RetroAchievements and save credentials.\nPrompts for password if --password is not given."
        when "verify"       then "Usage: gemba ra verify\n\nVerify stored RetroAchievements credentials are still valid."
        when "logout"       then "Usage: gemba ra logout\n\nClear stored RetroAchievements credentials."
        when "achievements" then "Usage: gemba ra achievements --rom PATH [--json]\n\nList achievements for a ROM."
        when "sync"         then "Usage: gemba ra sync ROM_FILE\n\nFetch achievements + earned state and write the offline cache."
        else                     "Usage: gemba ra <subcommand> [options]\n\nSubcommands: #{RA_SUBCOMMANDS.join(", ")}"
        end
      end

      private def login(plan : Plan) : Nil
        username = plan.username ||
                   raise Error.new("--username USER is required\nRun 'gemba ra login --help' for usage")
        password = plan.password || prompt_password

        json, ok = @requester.call({"r" => "login2", "u" => username, "p" => password})
        unless json && ok && json["Success"]?.try(&.as_bool?)
          raise Error.new("Login failed: #{error_message(json, ok)}")
        end

        config = Config.new(@config_path)
        config.ra_username = username
        config.ra_token = json["Token"].as_s
        config.ra_enabled = true
        config.save!
        @io.puts "Logged in as #{username}"
      end

      private def verify : Nil
        username, token = credentials!
        json, ok = @requester.call({"r" => "login2", "u" => username, "t" => token})
        unless json && ok && json["Success"]?.try(&.as_bool?)
          raise Error.new("Token invalid or expired. Run: gemba ra login --username USER")
        end

        @io.puts "Token valid for #{username}"
      end

      private def logout : Nil
        config = Config.new(@config_path)
        config.ra_username = ""
        config.ra_token = ""
        config.ra_enabled = false
        config.save!
        @io.puts "Logged out"
      end

      private def achievements(plan : Plan) : Nil
        rom = plan.rom || raise Error.new("--rom PATH is required\nRun 'gemba ra achievements --help' for usage")
        list = fetch_list(rom)
        title = File.basename(rom).sub(/\.gba$/i, "")

        if plan.json
          print_json(list)
        else
          @io.puts "#{list.count(&.earned?)}/#{list.size} achievements - #{title}"
          @io.puts
          list.each do |achievement|
            mark = achievement.earned? ? "X" : " "
            @io.puts "  [#{mark}] #{achievement.title} (#{achievement.points}pts)"
            @io.puts "       #{achievement.description}"
          end
        end
      end

      # This port's addition (the bead's `gemba ra sync rom.gba`): the
      # same fetch as `achievements`, written to the offline cache the
      # in-app browser reads (Achievements::Cache) instead of printed.
      private def sync(plan : Plan) : Nil
        rom = plan.rom || raise Error.new("sync requires a ROM file\nRun 'gemba ra sync --help' for usage")
        list = fetch_list(rom)

        # The cache is keyed by the app's rom_id (game code + header
        # CRC) - read from the cart header, same as a live session.
        core = Core.new(rom)
        rom_id = RomLibrary.rom_id(core.game_code, core.checksum)
        core.destroy

        Achievements::Cache.write(rom_id, list, @cache_dir)
        @io.puts "Synced #{list.size} achievements (#{list.count(&.earned?)} earned) for #{File.basename(rom)}"
        @io.puts "Cache: #{Achievements::Cache.path(rom_id, @cache_dir)}"
      end

      # gameid -> patch -> unlocks, earned state merged in - the same
      # chain (and ordering) MainWindow#start_ra_session runs async.
      private def fetch_list(rom : String) : Array(Achievements::Achievement)
        raise Error.new("ROM not found: #{rom}") unless File.exists?(rom)
        username, token = credentials!

        md5 = Achievements::RomHash.for_file(rom)
        json, ok = @requester.call({"r" => "gameid", "m" => md5})
        game_id = json.try(&.["GameID"]?.try(&.as_i64?)) if ok
        unless game_id && game_id > 0
          raise Error.new("No achievements found (game not recognized by RetroAchievements)")
        end

        patch, patch_ok = @requester.call({"r" => "patch", "u" => username, "t" => token, "g" => game_id.to_s})
        data = patch.try(&.["PatchData"]?) if patch_ok
        raise Error.new("Failed to fetch achievement definitions") unless data
        list = Achievements::Achievement.from_patch(data["Achievements"]?, Config.new(@config_path).ra_unofficial?)

        earned = fetch_earned(username, token, game_id)
        list.map { |achievement| earned.includes?(achievement.id) ? achievement.earn : achievement }
      end

      private def fetch_earned(username : String, token : String, game_id : Int64) : Set(UInt32)
        json, ok = @requester.call({"r" => "unlocks", "u" => username, "t" => token, "g" => game_id.to_s, "h" => "0"})
        unless json && ok && json["Success"]?.try(&.as_bool?)
          raise Error.new("Failed to fetch earned state")
        end

        ids = Set(UInt32).new
        json["UserUnlocks"]?.try(&.as_a?).try &.each do |value|
          id = value.as_i64? || value.as_s?.try(&.to_i64?)
          ids << id.to_u32 if id && id > 0
        end
        ids
      end

      private def print_json(list : Array(Achievements::Achievement)) : Nil
        # Built into a local first: a bare `puts JSON.build do` hands
        # the block to puts, not to JSON.build.
        text = JSON.build do |builder|
          builder.array do
            list.each do |achievement|
              builder.object do
                builder.field "id", achievement.id
                builder.field "title", achievement.title
                builder.field "description", achievement.description
                builder.field "points", achievement.points
                builder.field "earned", achievement.earned?
                builder.field "earned_at", achievement.earned_at.try(&.to_rfc3339)
              end
            end
          end
        end
        @io.puts text
      end

      private def credentials! : {String, String}
        config = Config.new(@config_path)
        username = config.ra_username
        token = config.ra_token
        if username.empty? || token.empty?
          raise Error.new("Not logged in. Run: gemba ra login --username USER")
        end
        {username, token}
      end

      # Hidden entry on a real terminal, plain gets on anything else
      # (a spec's IO::Memory, a pipe).
      private def prompt_password : String
        @err.print "Password: "
        input = @input
        password = if input.is_a?(IO::FileDescriptor) && input.tty?
                     value = input.noecho(&.gets)
                     @err.puts
                     value
                   else
                     input.gets
                   end
        password.try(&.chomp).presence || raise Error.new("password required")
      end

      private def error_message(json : JSON::Any?, request_ok : Bool) : String
        return "Could not connect to RetroAchievements" unless request_ok

        json.try(&.["Error"]?.try(&.as_s?)) || "Request failed"
      end

      @parser : OptionParser?
    end
  end
end
