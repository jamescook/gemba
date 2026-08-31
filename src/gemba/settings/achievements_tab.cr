require "tryst"
require "tryst/ui"
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
    # Built through the Tryst::UI DSL (Session#add against SettingsWindow's
    # shared notebook Handle, inside this tab's own ui.component so its
    # widget names stay local to it) - see its own class comment, and
    # GamepadTab's for the general pattern. The readonly
    # gray-background credential fields (@username_ro/@token_ro) are the
    # one piece with no DSL-native equivalent: :text_box always creates
    # ttk::entry, but the readonly display variant needs classic
    # tk::entry (only that one supports a settable background color, the
    # same trick ruby's own RO fields use) - built via the DSL's own
    # #raw escape hatch instead, parented at the (by-then-realized)
    # credentials row looked up by name.
    class AchievementsTab
      # Public getters onto the real controls - a spec drives/reads the
      # same widgets #load_from_config itself writes, matching every
      # other tab's own convention.
      getter enabled_switch : Tryst::Switch
      getter rich_presence_switch : Tryst::Switch
      getter screenshot_switch : Tryst::Switch

      @frame : String
      @creds_row : String
      @username_entry : String
      @token_entry : String
      @token_lbl : String
      @username_ro : String
      @token_ro : String
      @login_btn : String
      @verify_btn : String
      @logout_btn : String
      @reset_btn : String
      @feedback_lbl : String

      def initialize(@app : Tryst::App, @session : Tryst::UI::Session, notebook : Tryst::UI::Handle,
                     @toplevel_path : String, @events : Events)
        @username_var = "::gemba_ra_username"
        @password_var = "::gemba_ra_password"
        @presenter = Achievements::CredentialsPresenter.with_defaults

        frame_handle = nil
        creds_row_handle = nil
        username_entry_handle = nil
        token_entry_handle = nil
        token_lbl_handle = nil
        login_btn_handle = nil
        verify_btn_handle = nil
        logout_btn_handle = nil
        reset_btn_handle = nil
        feedback_lbl_handle = nil

        @session.add(notebook) do |session|
          session.component(:achievements) do |scope|
            frame_handle = scope.tab(Locale.translate("settings.retroachievements"), :tab, pad: 12) do |tab|
              creds_row_handle = tab.row(:credentials_row, gap: 4, pad: 4) do |row|
                row.label(text: Locale.translate("settings.ra_username_placeholder"))
                username_entry_handle = row.text_box(:username, textvariable: @username_var, width: 18)
                token_lbl_handle = row.label(:token_label, text: Locale.translate("settings.ra_token_placeholder"))
                token_entry_handle = row.text_box(:token, textvariable: @password_var, show: "*", width: 18)
              end

              # The readonly tk::entry variants aren't DSL nodes (see class
              # comment) - #raw defers its block to link time, by which
              # every sibling above (creds_row_handle included) is already
              # realized, so closing over that local is safe here.
              tab.raw do |app_contract|
                row_path = realized!(creds_row_handle).path
                app_contract.command("entry", "#{row_path}.username_ro", textvariable: @username_var,
                  state: :readonly, readonlybackground: "#cccccc", relief: :sunken, width: 18)
                app_contract.command("entry", "#{row_path}.token_ro",
                  state: :readonly, readonlybackground: "#cccccc", relief: :sunken, width: 18)
              end

              tab.row(:actions_row, gap: 6, pad: 4) do |row|
                login_btn_handle = row.button(:login, text: Locale.translate("settings.ra_login"), state: :disabled,
                  command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) {
                    @events.ra_login_requested.emit(@app.get_variable(@username_var).strip, @app.get_variable(@password_var))
                    nil
                  })
                verify_btn_handle = row.button(:verify, text: Locale.translate("settings.ra_verify"), state: :disabled,
                  command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { @events.ra_verify_requested.emit; nil })
                logout_btn_handle = row.button(:logout, text: Locale.translate("settings.ra_logout"), state: :disabled,
                  command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { @events.ra_logout_requested.emit; nil })
                reset_btn_handle = row.button(:reset, text: Locale.translate("settings.ra_reset"), state: :disabled,
                  command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { confirm_reset; nil })
              end

              # padding: (ttk's own option) rather than the DSL's pad:,
              # which only a container takes.
              feedback_lbl_handle = tab.label(:feedback, text: "", anchor: :w, padding: 4)
            end
          end
        end

        @frame = realized!(frame_handle).path
        @creds_row = realized!(creds_row_handle).path
        @username_entry = realized!(username_entry_handle).path
        @token_entry = realized!(token_entry_handle).path
        @token_lbl = realized!(token_lbl_handle).path
        @username_ro = "#{@creds_row}.username_ro"
        @token_ro = "#{@creds_row}.token_ro"
        @login_btn = realized!(login_btn_handle).path
        @verify_btn = realized!(verify_btn_handle).path
        @logout_btn = realized!(logout_btn_handle).path
        @reset_btn = realized!(reset_btn_handle).path
        @feedback_lbl = realized!(feedback_lbl_handle).path

        @app.set_variable(@username_var, "")
        @app.set_variable(@password_var, "")

        # -- Enable / per-game switches -- not DSL nodes (see
        # SettingsWindow's own class comment), packed directly under the
        # tab frame the same as before.
        @enabled_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.ra_enabled"), parent: @frame)
        @enabled_switch.pack(anchor: :w, pady: 8)

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
        @app.command(@feedback_lbl, :cget, "-text")
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
          @app.command(:pack, :forget, @username_entry, @token_entry)
          @app.command(:pack, @username_ro, in: @creds_row, side: :left, padx: [0, 10], before: @token_lbl)
          @app.command(:pack, @token_ro, in: @creds_row, side: :left)
        else
          @app.command(:pack, :forget, @username_ro, @token_ro)
          @app.command(:pack, @username_entry, in: @creds_row, side: :left, padx: [0, 10], before: @token_lbl)
          @app.command(:pack, @token_entry, in: @creds_row, side: :left, after: @username_entry)
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

      # #add's block builds the whole subtree before anything realizes
      # (see #initialize's own comment on this), so every Handle it
      # hands back is genuinely always assigned by the time this runs -
      # a raise here means a bug in that build block, not a legitimate
      # nil case.
      private def realized!(handle : Tryst::UI::Handle?) : Tryst::UI::Handle
        handle || raise "AchievementsTab widget handle wasn't realized by Session#add - this is a bug in its own build block"
      end
    end
  end
end
