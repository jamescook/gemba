# frozen_string_literal: true

module Gemba
  module Achievements
    # Presents credential state for the RetroAchievements settings UI.
    # Read-only view of state — never writes to disk or config.
    #
    # Initialized from persisted config. Mutated by:
    #   - UI interactions (checkbox, keystrokes) via setters
    #   - Backend auth results via :ra_auth_result bus events
    #
    # Emits :credentials_changed on the bus whenever state changes.
    # SystemTab listens and calls apply_presenter_state to refresh widgets.
    #
    # Call dispose when discarding the presenter to remove the bus subscription.
    class CredentialsPresenter
      include BusEmitter

      def initialize(config)
        @enabled  = config.ra_enabled?
        @username = config.ra_username.to_s
        @token    = config.ra_token.to_s
        @password = ''
        @feedback_override = nil

        @auth_handler = ->(status:, token: nil, message: nil) {
          handle_auth_result(status, token, message)
        }
        Gemba.bus.on(:ra_auth_result, &@auth_handler)
      end

      # Remove bus subscription. Call before discarding the presenter.
      def dispose
        Gemba.bus.off(:ra_auth_result, @auth_handler)
      end

      # -- UI mutations ---------------------------------------------------------

      def enabled=(val)
        @enabled = val ? true : false
        emit(:credentials_changed)
      end

      def username=(val)
        @username = val.to_s
        emit(:credentials_changed)
      end

      def password=(val)
        @password = val.to_s
        emit(:credentials_changed)
      end

      # Transient feedback (e.g. "Connection OK ✓") that disappears after a delay.
      # Caller is responsible for scheduling clear_transient via Tk after.
      def show_transient(key, **kwargs)
        @feedback_override = { key: key, **kwargs }
        emit(:credentials_changed)
      end

      def clear_transient
        @feedback_override = nil
        emit(:credentials_changed)
      end

      # -- Read-only accessors --------------------------------------------------

      attr_reader :username, :password, :token
      def enabled?   = @enabled
      def logged_in? = !@token.strip.empty?

      # -- Widget state queries -------------------------------------------------

      def fields_state
        return :disabled unless @enabled
        return :readonly if logged_in?
        :normal
      end

      def login_button_state
        return :disabled unless @enabled
        return :disabled if logged_in?
        fields_filled? ? :normal : :disabled
      end

      def verify_button_state
        (@enabled && logged_in?) ? :normal : :disabled
      end

      def logout_button_state
        (@enabled && logged_in?) ? :normal : :disabled
      end

      def reset_button_state
        (@enabled && logged_in?) ? :normal : :disabled
      end

      # Feedback descriptor. key drives locale lookup in SystemTab.
      # :empty          → blank label
      # :not_logged_in  → "Not logged in"
      # :logged_in_as   → "Logged in as {username}"  (also carries username:)
      # :test_ok        → "Connection OK ✓"
      # :error          → error text (carries message:)
      def feedback
        return @feedback_override if @feedback_override
        return { key: :empty }          unless @enabled
        return { key: :logged_in_as, username: @username } if logged_in?
        { key: :not_logged_in }
      end

      private

      def handle_auth_result(status, token, message)
        case status
        when :ok
          if token
            # Login success — store token, clear password
            @token    = token.to_s
            @password = ''
            @feedback_override = nil
          else
            # Ping success — show transient then let SystemTab schedule clear
            @feedback_override = { key: :test_ok }
            emit(:ra_ping_ok)
          end
        when :error
          @feedback_override = { key: :error, message: message.to_s }
        when :logout
          @token    = ''
          @password = ''
          @feedback_override = nil
          # username intentionally kept so user can re-enter password quickly
        end
        emit(:credentials_changed)
      end

      def fields_filled?
        !@username.strip.empty? && !@password.strip.empty?
      end
    end
  end
end
