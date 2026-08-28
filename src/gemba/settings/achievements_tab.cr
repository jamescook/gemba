require "tryst"
require "tryst-switch"
require "../locale"
require "../events"
require "../config"
require "../achievements/credentials_presenter"

module Gemba
  module Settings
    # RetroAchievements only - ruby's BIOS section (same notebook tab
    # there) isn't ported here, since nothing in this port reads a BIOS
    # path yet.
    #
    # Built entirely inline in #initialize, not split into per-section
    # helper methods (see SettingsWindow's own comment on this exact
    # constraint): several control ivars (@enabled_switch,
    # @rich_presence_switch, @screenshot_switch) are only assigned
    # partway through, and Crystal bans any instance-method call on self
    # until every declared ivar has been assigned at least once.
    class AchievementsTab
      # Public getters onto the real controls - a spec drives/reads the
      # same widgets #load_from_config itself writes, matching every
      # other tab's own convention.
      getter enabled_switch : Tryst::Switch
      getter rich_presence_switch : Tryst::Switch
      getter screenshot_switch : Tryst::Switch

      def initialize(@app : Tryst::App, parent_notebook : String, @toplevel_path : String, @events : Events)
        @frame = "#{parent_notebook}.achievements"
        @creds_row = "#{@frame}.creds_row"
        @username_entry = "#{@creds_row}.username"
        @username_ro = "#{@creds_row}.username_ro"
        @token_entry = "#{@creds_row}.token"
        @token_ro = "#{@creds_row}.token_ro"
        @token_lbl = "#{@creds_row}.token_lbl"
        @btn_row = "#{@frame}.btn_row"
        @login_btn = "#{@btn_row}.login"
        @verify_btn = "#{@btn_row}.verify"
        @logout_btn = "#{@btn_row}.logout"
        @reset_btn = "#{@btn_row}.reset"
        @feedback_lbl = "#{@frame}.feedback"
        @username_var = "::gemba_ra_username"
        @password_var = "::gemba_ra_password"
        @presenter = Achievements::CredentialsPresenter.with_defaults

        @app.command("ttk::frame", @frame, padding: 12)
        @app.command(parent_notebook, :add, @frame, text: Locale.translate("settings.retroachievements"))

        # -- Enable switch --
        @enabled_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.ra_enabled"), parent: @frame)
        @enabled_switch.pack(anchor: :w, pady: 8)

        # -- Username / password row --
        @app.command("ttk::frame", @creds_row)
        @app.command(:pack, @creds_row, fill: :x, pady: [0, 4])

        username_lbl = "#{@creds_row}.username_lbl"
        @app.command("ttk::label", username_lbl, text: Locale.translate("settings.ra_username_placeholder"))
        @app.command(:pack, username_lbl, side: :left, padx: [0, 4])

        @app.set_variable(@username_var, "")
        @app.command("ttk::entry", @username_entry, textvariable: @username_var, width: 18)
        @app.command(:pack, @username_entry, side: :left, padx: [0, 10])

        # Readonly display variants - classic tk::entry (not ttk) so
        # their background color is settable, same trick as ruby's own
        # RO fields. Not packed initially; swapped in by
        # #apply_presenter_state once logged in.
        @app.command("entry", @username_ro, textvariable: @username_var, state: :readonly,
          readonlybackground: "#cccccc", relief: :sunken, width: 18)

        @app.command("ttk::label", @token_lbl, text: Locale.translate("settings.ra_token_placeholder"))
        @app.command(:pack, @token_lbl, side: :left, padx: [0, 4])

        @app.set_variable(@password_var, "")
        @app.command("ttk::entry", @token_entry, textvariable: @password_var, show: "*", width: 18)
        @app.command(:pack, @token_entry, side: :left)

        @app.command("entry", @token_ro, state: :readonly, readonlybackground: "#cccccc", relief: :sunken, width: 18)

        # -- Login / Verify / Logout / Reset buttons --
        @app.command("ttk::frame", @btn_row)
        @app.command(:pack, @btn_row, fill: :x, pady: [4, 0])

        @app.command("ttk::button", @login_btn, text: Locale.translate("settings.ra_login"), state: :disabled,
          command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) {
            @events.ra_login_requested.emit(@app.get_variable(@username_var).strip, @app.get_variable(@password_var))
            nil
          })
        @app.command(:pack, @login_btn, side: :left, padx: [0, 6])

        @app.command("ttk::button", @verify_btn, text: Locale.translate("settings.ra_verify"), state: :disabled,
          command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { @events.ra_verify_requested.emit; nil })
        @app.command(:pack, @verify_btn, side: :left, padx: [0, 6])

        @app.command("ttk::button", @logout_btn, text: Locale.translate("settings.ra_logout"), state: :disabled,
          command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { @events.ra_logout_requested.emit; nil })
        @app.command(:pack, @logout_btn, side: :left, padx: [0, 6])

        @app.command("ttk::button", @reset_btn, text: Locale.translate("settings.ra_reset"), state: :disabled,
          command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { confirm_reset; nil })
        @app.command(:pack, @reset_btn, side: :left)

        # -- Feedback label --
        @app.command("ttk::label", @feedback_lbl, text: "")
        @app.command(:pack, @feedback_lbl, anchor: :w, padx: 2, pady: [4, 6])

        # -- Per-game switches --
        @rich_presence_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.ra_rich_presence"), parent: @frame)
        @rich_presence_switch.pack(anchor: :w, pady: [0, 4])

        @screenshot_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.ra_screenshot_on_unlock"), parent: @frame)
        @screenshot_switch.pack(anchor: :w, pady: [0, 4])

        # -- Wiring (deferred until every ivar above is assigned) --
        @app.bind(@username_entry, :key_release) { |_values, _signal| @presenter.username = @app.get_variable(@username_var); apply_presenter_state }
        @app.bind(@token_entry, :key_release) { |_values, _signal| @presenter.password = @app.get_variable(@password_var); apply_presenter_state }

        @enabled_switch.on_action do |value|
          @presenter.enabled = value
          @events.ra_enabled_changed.emit(value)
          apply_presenter_state
        end
        @rich_presence_switch.on_action { |value| @events.ra_rich_presence_changed.emit(value) }
        @screenshot_switch.on_action { |value| @events.ra_screenshot_on_unlock_changed.emit(value) }
      end

      def path : String
        @frame
      end

      # Current feedback label text - for a spec to synchronize on
      # (wait_until) after emitting a login/verify Events signal.
      def feedback_text : String
        @app.tcl_eval("#{@feedback_lbl} cget -text")
      end

      # Pushes Config into the presenter and every widget - call before
      # showing the window (mirrors every other tab's #load_from_config).
      def load_from_config(config : Config) : Nil
        @presenter = Achievements::CredentialsPresenter.new(config)
        @app.set_variable(@username_var, @presenter.username)
        @app.set_variable(@password_var, "")
        @enabled_switch.value = @presenter.enabled?
        @rich_presence_switch.value = config.ra_rich_presence?
        @screenshot_switch.value = config.ra_screenshot_on_unlock?
        apply_presenter_state
      end

      # -- Auth-result callbacks (MainWindow, once its backend responds) --

      def login_succeeded(token : String) : Nil
        @presenter.login_succeeded(token)
        apply_presenter_state
      end

      def auth_failed(message : String) : Nil
        @presenter.auth_failed(message)
        apply_presenter_state
      end

      def ping_succeeded : Nil
        @presenter.ping_succeeded
        apply_presenter_state
      end

      def logged_out : Nil
        @presenter.logged_out
        apply_presenter_state
      end

      def clear_transient_feedback : Nil
        @presenter.clear_transient
        apply_presenter_state
      end

      private def apply_presenter_state : Nil
        swap_credential_fields(@presenter.fields_state == :readonly)

        @app.command(@login_btn, :configure, state: @presenter.login_button_state)
        @app.command(@verify_btn, :configure, state: @presenter.verify_button_state)
        @app.command(@logout_btn, :configure, state: @presenter.logout_button_state)
        @app.command(@reset_btn, :configure, state: @presenter.reset_button_state)

        fb = @presenter.feedback
        text = case fb.key
               when :not_logged_in then Locale.translate("settings.ra_not_logged_in")
               when :logged_in_as  then Locale.translate("settings.ra_logged_in_as", username: fb.username.to_s)
               when :test_ok       then Locale.translate("settings.ra_test_ok")
               when :error         then fb.message.to_s
               else                     ""
               end
        @app.command(@feedback_lbl, :configure, text: text)

        @app.set_variable(@username_var, @presenter.username)
      end

      # Swaps between editable ttk::entry widgets and gray readonly
      # tk::entry widgets - uses pack -before to preserve visual order
      # relative to the token label, same as ruby's own swap_cred_fields.
      private def swap_credential_fields(readonly : Bool) : Nil
        if readonly
          @app.tcl_eval("pack forget #{@username_entry} #{@token_entry}")
          @app.tcl_eval("pack #{@username_ro} -in #{@creds_row} -side left -padx {0 10} -before #{@token_lbl}")
          @app.tcl_eval("pack #{@token_ro} -in #{@creds_row} -side left")
        else
          @app.tcl_eval("pack forget #{@username_ro} #{@token_ro}")
          @app.tcl_eval("pack #{@username_entry} -in #{@creds_row} -side left -padx {0 10} -before #{@token_lbl}")
          @app.tcl_eval("pack #{@token_entry} -in #{@creds_row} -side left -after #{@username_entry}")
          @app.command(@username_entry, :configure, state: @presenter.fields_state)
          @app.command(@token_entry, :configure, state: @presenter.fields_state)
        end
      end

      private def confirm_reset : Nil
        confirmed = @app.message_box(Locale.translate("settings.ra_reset_confirm"),
          title: Locale.translate("settings.ra_reset_title"), type: :yesno, icon: :warning) == :yes
        return unless confirmed

        @presenter.username = ""
        @presenter.logged_out
        @app.set_variable(@username_var, "")
        @app.set_variable(@password_var, "")
        @events.ra_reset_requested.emit
        apply_presenter_state
      end
    end
  end
end
