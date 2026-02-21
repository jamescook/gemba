# frozen_string_literal: true

module Gemba
  module Achievements
    # Abstract interface for achievement backends.
    #
    # All methods have no-op defaults so backends only need to override
    # what they support. Concrete backends: NullBackend, FakeBackend,
    # and the future RetroAchievements backend.
    #
    # Thread safety: do_frame is called from the emulation thread (Tk
    # after-loop). on_unlock and on_auth_change callbacks fire on the
    # same thread.
    #
    # Authentication lifecycle (decoupled from the real network):
    #   1. call login(username:, token:) — may be async
    #   2. on_auth_change callback fires with status :ok or :error
    #   3. authenticated? reflects the current state
    #   4. call logout to clear credentials
    module Backend
      # -- Authentication -------------------------------------------------------

      # Initiate login with username + password (first-time auth).
      # On success the on_auth_change callback fires with :ok and the
      # returned API token is yielded so the caller can persist it:
      #   on_auth_change { |status, token_or_error| ... }
      # NullBackend ignores this call.
      #
      # @param username [String]
      # @param password [String]
      def login_with_password(username:, password:); end

      # Resume a session using a previously stored API token.
      # Called automatically at startup when credentials are already saved.
      #
      # @param username [String]
      # @param token    [String]
      def login_with_token(username:, token:); end

      # Clear authentication state and stored session.
      def logout; end

      # @return [Boolean] true when authenticated and ready to serve achievements
      def authenticated?
        false
      end

      # Register a callback invoked when authentication state changes.
      # Fired with `status` (:ok or :error) and an optional `error` message.
      #
      # @yield [Symbol, String, nil] status, error (nil on success)
      def on_auth_change(&block)
        @auth_callbacks ||= []
        @auth_callbacks << block
      end

      # -- Game lifecycle -------------------------------------------------------

      # Called once per emulated frame. Evaluate achievement conditions and
      # fire on_unlock callbacks for any newly earned achievements.
      #
      # @param core [Gemba::Core] the live mGBA core
      def do_frame(core); end

      # Called when a new ROM is loaded. Backend should reset per-game state
      # and re-identify the game.
      #
      # @param core     [Gemba::Core]
      # @param rom_path [String, nil] path to the ROM file (used for MD5 hashing by network backends)
      def load_game(core, rom_path = nil, md5 = nil); end

      # Called when the ROM is unloaded / emulator stops.
      def unload_game; end

      # Called when a save state is loaded.  Memory jumped to an arbitrary saved
      # state; all achievements must restart their priming/waiting sequence.
      def reset_runtime; end

      # -- Rich Presence --------------------------------------------------------

      # Current Rich Presence display string for the active game, or nil if
      # not loaded / not supported. Updated by do_frame in real backends.
      def rich_presence_message
        nil
      end

      # Enable or disable Rich Presence evaluation for the current game.
      # Pushed from AppController when per-game config is resolved at ROM load.
      def rich_presence_enabled=(val); end

      # Register a callback fired when the Rich Presence string changes.
      # Called with the new message string.
      #
      # @yield [String] the new rich presence message
      def on_rich_presence_changed(&block)
        @rp_callbacks ||= []
        @rp_callbacks << block
      end

      # -- Achievement list -----------------------------------------------------

      # Register a callback invoked when an achievement is unlocked.
      # Multiple callbacks can be registered; all are called in order.
      #
      # @yield [Achievement] the newly earned achievement
      def on_unlock(&block)
        @unlock_callbacks ||= []
        @unlock_callbacks << block
      end

      # @return [Array<Achievement>] all achievements for the current game
      def achievement_list
        []
      end

      # @return [Integer] number of earned achievements
      def earned_count
        achievement_list.count(&:earned?)
      end

      # @return [Integer] total achievements for the current game
      def total_count
        achievement_list.size
      end

      # Verify the stored token is still valid. Result fires on_auth_change.
      # Used by the "Verify Token" button in settings.
      def token_test; end

      # @return [Boolean] true if this backend is active / enabled
      def enabled?
        false
      end

      # Fetch already-earned achievements from the server and merge them into
      # the local earned state so the UI reflects prior progress. No-op for
      # backends that have no server. Fires on_achievements_changed on
      # completion.
      def sync_unlocks; end

      # Called on app exit. Backends with pending network state should flush
      # or log anything that couldn't be delivered.
      def shutdown; end

      # Fetch the full achievement list for a given ROM (by RomInfo) purely for
      # display — does not affect live game state. Calls the block with
      # Array<Achievement> on success, or nil on failure/unsupported.
      # No-op (calls block with nil) for backends without a server.
      #
      # @param rom_info [RomInfo]
      # @yield [Array<Achievement>, nil]
      def fetch_for_display(rom_info:, &callback)
        callback&.call(nil)
      end

      # Set whether unofficial (Flags=5) achievements are included in
      # display syncs and live evaluation. No-op for backends that don't
      # distinguish official vs unofficial.
      def include_unofficial=(val); end

      # Register a callback invoked when the achievement list changes in bulk
      # (e.g. after a game loads or sync_unlocks completes). Use this to
      # refresh list UI without wiring individual on_unlock callbacks.
      #
      # @yield called with no arguments
      def on_achievements_changed(&block)
        @achievements_changed_callbacks ||= []
        @achievements_changed_callbacks << block
      end

      private

      def fire_unlock(achievement)
        @unlock_callbacks&.each { |cb| cb.call(achievement) }
      end

      def fire_auth_change(status, error = nil)
        @auth_callbacks&.each { |cb| cb.call(status, error) }
      end

      def fire_achievements_changed
        @achievements_changed_callbacks&.each(&:call)
      end

      def fire_rich_presence_changed(message)
        @rp_callbacks&.each { |cb| cb.call(message) }
      end
    end
  end
end
