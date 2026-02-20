# frozen_string_literal: true

module Gemba
  module Achievements
    # Achievement backend backed by a local database — no HTTP, no rcheevos.
    # Auth is a no-op: always authenticated.
    #
    # The DB maps ROM checksum → array of achievement definition Hashes:
    #   {
    #     id:, title:, description:, points:,
    #     trigger: :on_load | :memory,
    #     condition: ->(mem) { bool }   # :memory trigger only
    #   }
    #
    # :on_load achievements fire immediately in load_game.
    # :memory achievements are evaluated each frame in do_frame (rising edge).
    #
    # Long-term this DB can be populated by RcheevosBackend after a successful
    # server sync, enabling offline play. For now it ships with a small
    # built-in set (one achievement for the GEMBATEST fixture ROM).
    #
    # Tests assign this backend directly:
    #   frame.achievement_backend = Achievements::OfflineBackend.new
    class OfflineBackend
      include Backend

      # Built-in achievement definitions, keyed by ROM checksum.
      BUILTIN_DB = {
        # test/fixtures/test.gba — checksum 3369266971, title "GEMBATEST"
        3369266971 => [
          {
            id:          'gembatest_loaded',
            title:       'Ready to Play',
            description: 'Loaded the Gemba test ROM',
            points:      1,
            trigger:     :on_load,
          },
        ],
      }.freeze

      # @param db [Hash, nil] fully replaces BUILTIN_DB when provided.
      #   Pass BUILTIN_DB.merge(extras) explicitly if you want both.
      def initialize(db: nil)
        @db = db || BUILTIN_DB
        @achievements = []
        @earned       = {}
        @prev_state   = {}
      end

      # -- Authentication (no-op — offline backend is always authenticated) ------

      def login_with_password(username:, password:)
        return fire_auth_change(:error, 'Username and password required') if username.to_s.strip.empty? || password.to_s.strip.empty?
        # Offline backend accepts any credentials — real auth happens via rcheevos
        fire_auth_change(:ok, "offline_token_#{username.strip}")
      end

      def login_with_token(username:, token:)
        return if token.to_s.strip.empty?
        fire_auth_change(:ok, nil)
      end

      def logout
        fire_auth_change(:logout)
      end

      def authenticated? = true

      def ping
        fire_auth_change(:ok, nil)
      end

      # -- Game lifecycle -------------------------------------------------------

      def load_game(core, rom_path = nil, md5 = nil)
        @achievements = []
        @earned       = {}
        @prev_state   = {}

        (@db[core.checksum] || []).each do |defn|
          ach = Achievement.new(
            id:          defn[:id],
            title:       defn[:title],
            description: defn[:description],
            points:      defn[:points],
            earned_at:   nil,
          )
          @achievements << ach
          @prev_state[ach.id] = false

          if defn[:trigger] == :on_load
            earned = ach.earn
            @earned[ach.id] = earned
            fire_unlock(earned)
          end
        end
      end

      def unload_game
        @achievements = []
        @earned       = {}
        @prev_state   = {}
      end

      # -- Per-frame evaluation (memory-condition achievements) -----------------

      def do_frame(core)
        (@db[core.checksum] || []).each do |defn|
          next unless defn[:trigger] == :memory
          next if @earned.key?(defn[:id])

          condition = defn[:condition]
          next unless condition

          read_mem = ->(addr) { core.bus_read8(addr) }
          current  = condition.call(read_mem) ? true : false

          if current && !@prev_state[defn[:id]]
            ach = @achievements.find { |a| a.id == defn[:id] }
            if ach
              earned = ach.earn
              @earned[ach.id] = earned
              fire_unlock(earned)
            end
          end

          @prev_state[defn[:id]] = current
        end
      end

      # -- Achievement list -----------------------------------------------------

      def achievement_list
        @achievements.map { |a| @earned[a.id] || a }
      end

      def enabled? = true

      # -- DB management --------------------------------------------------------

      # Merge achievement definitions for a ROM into the in-memory DB.
      # Intended for use by RcheevosBackend to seed the offline cache.
      #
      # @param checksum [Integer]
      # @param defs     [Array<Hash>]
      def store(checksum, defs)
        @db = @db.merge(checksum => defs)
      end
    end
  end
end
