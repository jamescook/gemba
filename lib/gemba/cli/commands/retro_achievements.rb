# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    module Commands
      class RetroAchievements
        RA_SUBCOMMANDS = %w[login verify logout achievements].freeze

        def initialize(argv, dry_run: false, config: nil, requester: nil)
          @argv      = argv
          @dry_run   = dry_run
          @config    = config
          @requester = requester
        end

        def call
          options = parse

          if options[:help] || options[:subcommand].nil?
            puts options[:parser] unless @dry_run
            return { command: :ra, help: true, subcommand: options[:subcommand] }
          end

          result = { command: :"ra_#{options[:subcommand]}", **options.except(:parser) }
          return result if @dry_run

          require "gemba"
          require "gemba/achievements/retro_achievements/cli_sync_requester"

          config    = @config    || Gemba.user_config
          requester = @requester || Gemba::Achievements::RetroAchievements::CliSyncRequester.new

          case options[:subcommand]
          when :login        then login(options,        config: config, requester: requester)
          when :verify       then verify(               config: config, requester: requester)
          when :logout       then logout(               config: config)
          when :achievements then achievements(options, config: config, requester: requester)
          end
        end

        def parse
          argv = @argv.dup
          sub  = RA_SUBCOMMANDS.include?(argv.first) ? argv.shift.to_sym : nil

          options = { subcommand: sub }

          parser = OptionParser.new do |o|
            case sub
            when :login
              o.banner = "Usage: gemba ra login --username USER [--password PASS]"
              o.separator ""
              o.separator "Log in to RetroAchievements and save credentials."
              o.separator "Prompts for password if --password is not given."
              o.separator ""
              o.on("--username USER", "RetroAchievements username") { |v| options[:username] = v }
              o.on("--password PASS", "Password (prompts if omitted)") { |v| options[:password] = v }
            when :verify
              o.banner = "Usage: gemba ra verify"
              o.separator ""
              o.separator "Verify stored RetroAchievements credentials are still valid."
              o.separator ""
            when :logout
              o.banner = "Usage: gemba ra logout"
              o.separator ""
              o.separator "Clear stored RetroAchievements credentials."
              o.separator ""
            when :achievements
              o.banner = "Usage: gemba ra achievements --rom PATH [--json]"
              o.separator ""
              o.separator "List achievements for a ROM."
              o.separator ""
              o.on("--rom PATH", "Path to the GBA ROM file") { |v| options[:rom] = File.expand_path(v) }
              o.on("--json", "Output as JSON")               { options[:json] = true }
            else
              o.banner = "Usage: gemba ra <subcommand> [options]"
              o.separator ""
              o.separator "Subcommands: #{RA_SUBCOMMANDS.join(', ')}"
              o.separator ""
            end
            o.on("-h", "--help", "Show this help") { options[:help] = true }
          end

          parser.parse!(argv)
          options[:parser] = parser
          options
        end

        private

        def login(options, config:, requester:)
          username = options[:username]
          unless username
            $stderr.puts "Error: --username USER is required"
            $stderr.puts "Run 'gemba ra login --help' for usage"
            exit 1
          end

          password = options[:password] || begin
            require "io/console"
            $stderr.print "Password: "
            pwd = $stdin.noecho(&:gets)&.chomp
            $stderr.puts
            pwd
          end

          backend = Gemba::Achievements::RetroAchievements::Backend.new(
            app: nil, requester: requester
          )
          result = nil
          backend.on_auth_change { |status, payload| result = [status, payload] }
          backend.login_with_password(username: username, password: password)

          if result&.first == :ok
            config.ra_username = username
            config.ra_token    = result[1]
            config.ra_enabled  = true
            config.save!
            puts "Logged in as #{username}"
          else
            $stderr.puts "Login failed: #{result&.[](1) || 'unknown error'}"
            exit 1
          end
        end

        def verify(config:, requester:)
          username = config.ra_username
          token    = config.ra_token

          if username.empty? || token.empty?
            $stderr.puts "Not logged in. Run: gemba ra login --username USER"
            exit 1
          end

          backend = Gemba::Achievements::RetroAchievements::Backend.new(
            app: nil, requester: requester
          )
          result = nil
          backend.on_auth_change { |status, _| result = status }
          backend.login_with_token(username: username, token: token)

          if result == :ok
            puts "Token valid for #{username}"
          else
            $stderr.puts "Token invalid or expired. Run: gemba ra login --username USER"
            exit 1
          end
        end

        def logout(config:)
          config.ra_username = ""
          config.ra_token    = ""
          config.ra_enabled  = false
          config.save!
          puts "Logged out"
        end

        def achievements(options, config:, requester:)
          username = config.ra_username
          token    = config.ra_token

          if username.empty? || token.empty?
            $stderr.puts "Not logged in. Run: gemba ra login --username USER"
            exit 1
          end

          unless options[:rom]
            $stderr.puts "Error: --rom PATH is required"
            $stderr.puts "Run 'gemba ra achievements --help' for usage"
            exit 1
          end

          require "digest"

          backend = Gemba::Achievements::RetroAchievements::Backend.new(
            app: nil, requester: requester
          )
          backend.login_with_token(username: username, token: token)

          rom_path = options[:rom]
          md5      = Digest::MD5.file(rom_path).hexdigest
          rom_info = Struct.new(:md5, :title).new(md5, File.basename(rom_path, ".*"))

          list = nil
          backend.fetch_for_display(rom_info: rom_info) { |result| list = result }

          if list.nil?
            $stderr.puts "No achievements found (game not recognized by RetroAchievements)"
            exit 1
          end

          if options[:json]
            require "json"
            puts JSON.generate(list.map { |a|
              { id: a.id, title: a.title, description: a.description,
                points: a.points, earned: a.earned?, earned_at: a.earned_at }
            })
          else
            earned = list.count(&:earned?)
            puts "#{earned}/#{list.size} achievements — #{rom_info.title}"
            puts
            list.each do |a|
              mark = a.earned? ? "X" : " "
              puts "  [#{mark}] #{a.title} (#{a.points}pts)"
              puts "       #{a.description}"
            end
          end
        end
      end
    end
  end
end
