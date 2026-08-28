module Gemba
  module Achievements
    # Presents credential state for the RetroAchievements settings tab -
    # read-only view of state, never writes to Config directly. Auth
    # results (#login_succeeded/#ping_succeeded/#auth_failed/#logged_out)
    # are plain public methods rather than a bus subscription.
    class CredentialsPresenter
      record Feedback, key : Symbol, username : String? = nil, message : String? = nil

      def initialize(config : Config)
        @enabled = config.ra_enabled?
        @username = config.ra_username
        @token = config.ra_token
        @password = ""
        @feedback_override = nil.as(Feedback?)
      end

      # Seeds from defaults rather than reading Config from disk - for a
      # caller (Settings::AchievementsTab#initialize) that needs a
      # presenter to render before #load_from_config ever runs, and
      # can't touch the filesystem from Tk's own thread at construction
      # time (see App's syscall guard).
      def self.with_defaults : CredentialsPresenter
        new(enabled: false, username: "", token: "")
      end

      def initialize(*, enabled : Bool, username : String, token : String)
        @enabled = enabled
        @username = username
        @token = token
        @password = ""
        @feedback_override = nil.as(Feedback?)
      end

      # -- UI mutations --------------------------------------------------

      def enabled=(value : Bool) : Nil
        @enabled = value
      end

      def username=(value : String) : Nil
        @username = value
      end

      def password=(value : String) : Nil
        @password = value
      end

      # Transient feedback (e.g. "Connection OK") - caller schedules
      # #clear_transient after a delay via App#after.
      def show_transient(key : Symbol) : Nil
        @feedback_override = Feedback.new(key)
      end

      def clear_transient : Nil
        @feedback_override = nil
      end

      # -- Auth-result methods (called once a real backend exists) ------

      def login_succeeded(token : String) : Nil
        @token = token
        @password = ""
        @feedback_override = nil
      end

      def ping_succeeded : Nil
        @feedback_override = Feedback.new(:test_ok)
      end

      def auth_failed(message : String) : Nil
        @feedback_override = Feedback.new(:error, message: message)
      end

      def logged_out : Nil
        @token = ""
        @password = ""
        @feedback_override = nil
        # username intentionally kept so the user can re-enter their password quickly
      end

      # -- Read-only accessors --------------------------------------------

      getter username : String
      getter password : String
      getter token : String

      def enabled? : Bool
        @enabled
      end

      def logged_in? : Bool
        !@token.strip.empty?
      end

      # -- Widget state queries --------------------------------------------

      def fields_state : Symbol
        return :disabled unless @enabled
        logged_in? ? :readonly : :normal
      end

      def login_button_state : Symbol
        return :disabled unless @enabled
        return :disabled if logged_in?
        fields_filled? ? :normal : :disabled
      end

      def verify_button_state : Symbol
        @enabled && logged_in? ? :normal : :disabled
      end

      def logout_button_state : Symbol
        @enabled && logged_in? ? :normal : :disabled
      end

      def reset_button_state : Symbol
        @enabled && logged_in? ? :normal : :disabled
      end

      # :empty, :not_logged_in, :logged_in_as (carries username), :test_ok, :error (carries message)
      def feedback : Feedback
        return @feedback_override.as(Feedback) if @feedback_override
        return Feedback.new(:empty) unless @enabled
        return Feedback.new(:logged_in_as, username: @username) if logged_in?
        Feedback.new(:not_logged_in)
      end

      private def fields_filled? : Bool
        !@username.strip.empty? && !@password.strip.empty?
      end
    end
  end
end
