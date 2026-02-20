# frozen_string_literal: true

module Gemba
  module Achievements
    # Pure-Ruby achievement backend for development and testing.
    #
    # Achievements are defined programmatically with a condition block
    # that receives a memory-read helper. No HTTP, no hashing, no server.
    #
    # Authentication behaviour:
    #   - By default any non-empty credentials succeed immediately.
    #   - Pass `valid_username:` and `valid_token:` to restrict: only that
    #     exact pair succeeds; anything else fails. Useful in tests that
    #     verify the "bad credentials" error path.
    #
    # Used in two ways:
    #   1. Automated tests — add achievements, step frames, assert unlocks
    #   2. Integration dev — iterate on UI (toasts, list) without rcheevos
    #
    # @example Basic usage
    #   backend = FakeBackend.new
    #   backend.add_achievement(id: 'btn_b', title: 'Press B',
    #                           description: 'Press the B button',
    #                           points: 5) do |mem|
    #     mem.call(0x02000000) == 0x42
    #   end
    #   backend.on_unlock { |ach| puts "Unlocked: #{ach.title}" }
    #   backend.do_frame(core)  # call each frame
    #
    # @example Restricted credentials (for testing failure path)
    #   backend = FakeBackend.new(valid_username: 'alice', valid_token: 'secret')
    #   backend.login(username: 'bob', token: 'wrong')   # → fires :error
    #   backend.login(username: 'alice', token: 'secret') # → fires :ok
    class FakeBackend
      include Backend

      # @param valid_username [String, nil] when set, only this username passes
      # @param valid_token    [String, nil] when set, only this token passes
      def initialize(valid_username: nil, valid_token: nil)
        @definitions = {}     # id → { achievement:, condition: }
        @earned = {}          # id → Achievement (earned copy)
        @prev_state = {}      # id → bool (condition result last frame)
        @valid_username = valid_username
        @valid_token = valid_token
        @authenticated = false
      end

      # -- Authentication -------------------------------------------------------

      # Resolves immediately. Succeeds if credentials are non-empty and match
      # the configured valid pair (or any non-empty creds if none configured).
      # On success fires on_auth_change(:ok, fake_token) where fake_token is
      # a deterministic stand-in so callers can exercise the token-persist path.
      def login_with_password(username:, password:)
        ok = !username.to_s.empty? && !password.to_s.empty? &&
             (@valid_username.nil? || username == @valid_username) &&
             (@valid_token.nil?    || password  == @valid_token)

        if ok
          @authenticated = true
          fire_auth_change(:ok, "fake_token_for_#{username}")
        else
          @authenticated = false
          fire_auth_change(:error, 'Invalid credentials (fake backend)')
        end
      end

      def login_with_token(username:, token:)
        ok = !username.to_s.empty? && !token.to_s.empty? &&
             (@valid_username.nil? || username == @valid_username) &&
             (@valid_token.nil?    || token    == @valid_token)

        if ok
          @authenticated = true
          fire_auth_change(:ok, token)
        else
          @authenticated = false
          fire_auth_change(:error, 'Invalid credentials (fake backend)')
        end
      end

      def logout
        @authenticated = false
        fire_auth_change(:logout)
      end

      def ping
        if @authenticated
          fire_auth_change(:ok, nil)
        else
          fire_auth_change(:error, 'Not authenticated (fake backend)')
        end
      end

      def authenticated?
        @authenticated
      end

      # Define an achievement. The block receives a read_mem callable
      # and must return truthy when the unlock condition is met.
      #
      # @param id [String] unique identifier
      # @param title [String]
      # @param description [String]
      # @param points [Integer]
      # @yield [read_mem] called each frame; read_mem is ->(address) { Integer }
      # @yieldreturn [Boolean] true when condition is satisfied
      def add_achievement(id:, title:, description:, points: 0, &condition)
        raise ArgumentError, "condition block required" unless condition
        ach = Achievement.new(id: id, title: title,
                              description: description,
                              points: points, earned_at: nil)
        @definitions[id] = { achievement: ach, condition: condition }
        @prev_state[id] = false
      end

      # Evaluate all unearned achievements against current memory state.
      # Fires on_unlock callbacks for newly met conditions (rising edge).
      #
      # @param core [Gemba::Core]
      def do_frame(core)
        read_mem = ->(addr) { core.bus_read8(addr) }
        @definitions.each do |id, defn|
          next if @earned.key?(id)

          current = defn[:condition].call(read_mem) ? true : false
          if current && !@prev_state[id]
            earned = defn[:achievement].earn
            @earned[id] = earned
            fire_unlock(earned)
          end
          @prev_state[id] = current
        end
      end

      def load_game(_core, rom_path = nil, md5 = nil)
        reset_earned
      end

      def unload_game
        reset_earned
      end

      # @return [Array<Achievement>] all achievements, earned ones updated
      def achievement_list
        @definitions.map do |id, defn|
          @earned[id] || defn[:achievement]
        end
      end

      def enabled?
        true
      end

      # Clear earned state (for test reuse).
      def reset_earned
        @earned = {}
        @prev_state = @prev_state.transform_values { false }
      end

      # Configure what fetch_for_display returns. Pass an Array (returned for
      # every rom_info) or a block that receives rom_info and returns an Array
      # or nil. Without calling this, fetch_for_display always calls back with nil.
      #
      # @example Always return a fixed list
      #   backend.stub_fetch_for_display([ach1, ach2])
      #
      # @example Vary by rom_info
      #   backend.stub_fetch_for_display { |rom_info| rom_info.rom_id == 'X' ? [ach1] : [] }
      def stub_fetch_for_display(list = nil, &block)
        @fetch_display_stub = block || ->(_) { list }
      end

      def fetch_for_display(rom_info:, &callback)
        result = @fetch_display_stub ? @fetch_display_stub.call(rom_info) : nil
        callback&.call(result)
      end
    end
  end
end
