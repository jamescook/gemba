# frozen_string_literal: true

module Gemba
  module Settings
    class SystemTab
      include Locale::Translatable
      include BusEmitter

      FRAME           = "#{Paths::NB}.system"
      BIOS_ENTRY      = "#{FRAME}.bios_row.entry"
      BIOS_BROWSE     = "#{FRAME}.bios_row.browse"
      BIOS_CLEAR      = "#{FRAME}.bios_row.clear"
      BIOS_STATUS     = "#{FRAME}.bios_status"
      SKIP_BIOS_CHECK = "#{FRAME}.skip_row.check"

      RA_ENABLED_CHECK  = "#{FRAME}.ra_enabled_row.check"
      RA_USERNAME_ENTRY = "#{FRAME}.ra_creds_row.username"
      RA_USERNAME_RO    = "#{FRAME}.ra_creds_row.username_ro"
      RA_TOKEN_ENTRY    = "#{FRAME}.ra_creds_row.token"
      RA_TOKEN_RO       = "#{FRAME}.ra_creds_row.token_ro"
      RA_LOGIN_BTN      = "#{FRAME}.ra_btn_row.login"
      RA_VERIFY_BTN     = "#{FRAME}.ra_btn_row.verify"
      RA_LOGOUT_BTN     = "#{FRAME}.ra_btn_row.logout"
      RA_RESET_BTN      = "#{FRAME}.ra_btn_row.reset"
      RA_FEEDBACK_LABEL = "#{FRAME}.ra_feedback"
      RA_HARDCORE_CHECK        = "#{FRAME}.ra_hardcore_row.check"
      RA_RICH_PRESENCE_CHECK   = "#{FRAME}.ra_rich_presence_row.check"
      RA_SCREENSHOT_CHECK      = "#{FRAME}.ra_screenshot_row.check"

      VAR_BIOS_PATH          = '::gemba_bios_path'
      VAR_SKIP_BIOS          = '::gemba_skip_bios'
      VAR_RA_ENABLED         = '::gemba_ra_enabled'
      VAR_RA_USERNAME        = '::gemba_ra_username'
      VAR_RA_TOKEN           = '::gemba_ra_token'
      VAR_RA_HARDCORE        = '::gemba_ra_hardcore'
      VAR_RA_UNOFFICIAL      = '::gemba_ra_unofficial'
      VAR_RA_PASSWORD        = '::gemba_ra_password'
      VAR_RA_RICH_PRESENCE      = '::gemba_ra_rich_presence'
      VAR_RA_SCREENSHOT         = '::gemba_ra_screenshot_on_unlock'

      RA_UNOFFICIAL_CHECK = "#{FRAME}.ra_unofficial_row.check"

      def initialize(app, tips:, mark_dirty:)
        @app = app
        @tips = tips
        @mark_dirty = mark_dirty
      end

      def build
        @app.command('ttk::frame', FRAME)
        @app.command(Paths::NB, 'add', FRAME, text: translate('settings.system'))

        build_bios_section
        build_skip_bios_row
        build_ra_section
      end

      # Called by SettingsWindow via :config_loaded bus event
      def load_from_config(config)
        name = config.bios_path
        @app.set_variable(VAR_BIOS_PATH, name.to_s)
        @app.set_variable(VAR_SKIP_BIOS, config.skip_bios? ? '1' : '0')
        if name && !name.empty?
          bios = Bios.from_config_name(name)
          update_status(bios)
        else
          @app.command(BIOS_STATUS, :configure, text: translate('settings.bios_not_set'))
        end

        @app.set_variable(VAR_RA_ENABLED,        config.ra_enabled?        ? '1' : '0')
        @app.set_variable(VAR_RA_USERNAME,       config.ra_username.to_s)
        @app.set_variable(VAR_RA_HARDCORE,       config.ra_hardcore?       ? '1' : '0')
        @app.set_variable(VAR_RA_UNOFFICIAL,     config.ra_unofficial?     ? '1' : '0')
        @app.set_variable(VAR_RA_RICH_PRESENCE,   config.ra_rich_presence?        ? '1' : '0')
        @app.set_variable(VAR_RA_SCREENSHOT,      config.ra_screenshot_on_unlock? ? '1' : '0')
        @app.set_variable(VAR_RA_PASSWORD, '')

        @presenter&.dispose
        @presenter = Achievements::CredentialsPresenter.new(config)
        Gemba.bus.on(:credentials_changed) { apply_presenter_state }
        Gemba.bus.on(:ra_token_test_ok) { @app.after(3000) { @presenter&.clear_transient } }
        apply_presenter_state
      end

      # Called by AppController#save_config
      def save_to_config(config)
        config.ra_enabled        = @app.get_variable(VAR_RA_ENABLED)        == '1'
        config.ra_username       = @presenter ? @presenter.username : @app.get_variable(VAR_RA_USERNAME).to_s.strip
        config.ra_token          = @presenter ? @presenter.token    : ''
        config.ra_hardcore       = @app.get_variable(VAR_RA_HARDCORE)       == '1'
        config.ra_rich_presence        = @app.get_variable(VAR_RA_RICH_PRESENCE) == '1'
        config.ra_screenshot_on_unlock = @app.get_variable(VAR_RA_SCREENSHOT)    == '1'
        # Password is never persisted — ephemeral field only
      end

      private

      def build_bios_section
        hdr = "#{FRAME}.bios_hdr"
        @app.command('ttk::label', hdr, text: translate('settings.bios_header'))
        @app.command(:pack, hdr, anchor: :w, padx: 10, pady: [15, 2])

        row = "#{FRAME}.bios_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: [0, 4])

        @app.set_variable(VAR_BIOS_PATH, '')
        @app.command('ttk::entry', BIOS_ENTRY,
          textvariable: VAR_BIOS_PATH,
          state: :readonly,
          width: 42)
        @app.command(:pack, BIOS_ENTRY, side: :left, fill: :x, expand: 1, padx: [0, 4])

        @app.command('ttk::button', BIOS_BROWSE,
          text: translate('settings.bios_browse'),
          command: proc { browse_bios })
        @app.command(:pack, BIOS_BROWSE, side: :left, padx: [0, 4])

        @app.command('ttk::button', BIOS_CLEAR,
          text: translate('settings.bios_clear'),
          command: proc { clear_bios })
        @app.command(:pack, BIOS_CLEAR, side: :left)

        @app.command('ttk::label', BIOS_STATUS, text: translate('settings.bios_not_set'))
        @app.command(:pack, BIOS_STATUS, anchor: :w, padx: 14, pady: [0, 10])
      end

      def build_skip_bios_row
        row = "#{FRAME}.skip_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: [0, 5])

        @app.set_variable(VAR_SKIP_BIOS, '0')
        @app.command('ttk::checkbutton', SKIP_BIOS_CHECK,
          text: translate('settings.skip_bios'),
          variable: VAR_SKIP_BIOS,
          command: proc { @mark_dirty.call })
        @app.command(:pack, SKIP_BIOS_CHECK, side: :left)

        tip_lbl = "#{row}.tip"
        @app.command('ttk::label', tip_lbl, text: '(?)')
        @app.command(:pack, tip_lbl, side: :left, padx: [4, 0])
        @tips.register(tip_lbl, translate('settings.tip_skip_bios'))
      end

      def build_ra_section
        sep = "#{FRAME}.ra_sep"
        @app.command('ttk::separator', sep, orient: :horizontal)
        @app.command(:pack, sep, fill: :x, padx: 10, pady: [12, 0])

        hdr = "#{FRAME}.ra_hdr"
        @app.command('ttk::label', hdr, text: translate('settings.retroachievements'))
        @app.command(:pack, hdr, anchor: :w, padx: 10, pady: [8, 2])

        # Enable checkbox
        enabled_row = "#{FRAME}.ra_enabled_row"
        @app.command('ttk::frame', enabled_row)
        @app.command(:pack, enabled_row, fill: :x, padx: 10, pady: [0, 6])
        @app.set_variable(VAR_RA_ENABLED, '0')
        @app.command('ttk::checkbutton', RA_ENABLED_CHECK,
          text: translate('settings.ra_enabled'),
          variable: VAR_RA_ENABLED,
          command: proc { @mark_dirty.call; @presenter&.enabled = (@app.get_variable(VAR_RA_ENABLED) == '1') })
        @app.command(:pack, RA_ENABLED_CHECK, side: :left)

        # Username + password fields
        creds_row = "#{FRAME}.ra_creds_row"
        @app.command('ttk::frame', creds_row)
        @app.command(:pack, creds_row, fill: :x, padx: 10, pady: [0, 4])

        @app.command('ttk::label', "#{creds_row}.username_lbl",
          text: translate('settings.ra_username_placeholder'))
        @app.command(:pack, "#{creds_row}.username_lbl", side: :left, padx: [0, 4])

        @app.set_variable(VAR_RA_USERNAME, '')
        @app.command('ttk::entry', RA_USERNAME_ENTRY,
          textvariable: VAR_RA_USERNAME,
          width: 18)
        @app.command(:pack, RA_USERNAME_ENTRY, side: :left, padx: [0, 10])
        @app.command(:bind, RA_USERNAME_ENTRY, '<KeyRelease>', proc { @presenter&.username = @app.get_variable(VAR_RA_USERNAME) })

        # Readonly display variant — tk::entry so we can control background color.
        # Not packed initially; swapped in by apply_presenter_state when logged in.
        @app.command('entry', RA_USERNAME_RO,
          textvariable: VAR_RA_USERNAME,
          state: :readonly,
          readonlybackground: '#cccccc',
          relief: :sunken,
          width: 18)

        pw_lbl = "#{creds_row}.pw_lbl"
        @app.command('ttk::label', pw_lbl,
          text: translate('settings.ra_token_placeholder'))
        @app.command(:pack, pw_lbl, side: :left, padx: [0, 4])
        @tips.register(pw_lbl, translate('settings.tip_ra_password'))

        @app.set_variable(VAR_RA_PASSWORD, '')
        @app.command('ttk::entry', RA_TOKEN_ENTRY,
          textvariable: VAR_RA_PASSWORD,
          show: '*',
          width: 18)
        @app.command(:pack, RA_TOKEN_ENTRY, side: :left)
        @app.command(:bind, RA_TOKEN_ENTRY, '<KeyRelease>', proc { @presenter&.password = @app.get_variable(VAR_RA_PASSWORD) })

        # Readonly password display — always empty after login (password is ephemeral).
        # Not packed initially; swapped in by apply_presenter_state when logged in.
        @app.command('entry', RA_TOKEN_RO,
          state: :readonly,
          readonlybackground: '#cccccc',
          relief: :sunken,
          width: 18)

        # Login / Test / Logout buttons
        btn_row = "#{FRAME}.ra_btn_row"
        @app.command('ttk::frame', btn_row)
        @app.command(:pack, btn_row, fill: :x, padx: 10, pady: [4, 0])

        @app.command('ttk::button', RA_LOGIN_BTN,
          text: translate('settings.ra_login'),
          state: :disabled,
          command: proc { emit(:ra_login,
            username: @app.get_variable(VAR_RA_USERNAME).strip,
            password: @app.get_variable(VAR_RA_PASSWORD)) })
        @app.command(:pack, RA_LOGIN_BTN, side: :left, padx: [0, 6])

        @app.command('ttk::button', RA_VERIFY_BTN,
          text: translate('settings.ra_verify'),
          state: :disabled,
          command: proc { emit(:ra_verify) })
        @app.command(:pack, RA_VERIFY_BTN, side: :left, padx: [0, 6])

        @app.command('ttk::button', RA_LOGOUT_BTN,
          text: translate('settings.ra_logout'),
          state: :disabled,
          command: proc { emit(:ra_logout) })
        @app.command(:pack, RA_LOGOUT_BTN, side: :left, padx: [0, 6])

        @app.command('ttk::button', RA_RESET_BTN,
          text: translate('settings.ra_reset'),
          state: :disabled,
          command: proc { confirm_ra_reset })
        @app.command(:pack, RA_RESET_BTN, side: :left)

        # Feedback label — shows auth result, errors, etc.
        @app.command('ttk::label', RA_FEEDBACK_LABEL, text: '')
        @app.command(:pack, RA_FEEDBACK_LABEL, anchor: :w, padx: 14, pady: [4, 6])

        # Rich Presence (per-game)
        rp_row = "#{FRAME}.ra_rich_presence_row"
        @app.command('ttk::frame', rp_row)
        @app.command(:pack, rp_row, fill: :x, padx: 10, pady: [0, 4])
        @app.set_variable(VAR_RA_RICH_PRESENCE, '0')
        @app.command('ttk::checkbutton', RA_RICH_PRESENCE_CHECK,
          text: translate('settings.ra_rich_presence'),
          variable: VAR_RA_RICH_PRESENCE,
          command: proc { @mark_dirty.call })
        @app.command(:pack, RA_RICH_PRESENCE_CHECK, side: :left)

        # Screenshot on achievement unlock (per-game)
        ss_row = "#{FRAME}.ra_screenshot_row"
        @app.command('ttk::frame', ss_row)
        @app.command(:pack, ss_row, fill: :x, padx: 10, pady: [0, 4])
        @app.set_variable(VAR_RA_SCREENSHOT, '1')
        @app.command('ttk::checkbutton', RA_SCREENSHOT_CHECK,
          text: translate('settings.ra_screenshot_on_unlock'),
          variable: VAR_RA_SCREENSHOT,
          command: proc { @mark_dirty.call })
        @app.command(:pack, RA_SCREENSHOT_CHECK, side: :left)

        # TODO: hardcore mode — not yet wired up, hidden until ready
        # hardcore_row = "#{FRAME}.ra_hardcore_row"
        # @app.command('ttk::frame', hardcore_row)
        # @app.command(:pack, hardcore_row, fill: :x, padx: 10, pady: [0, 4])
        # @app.set_variable(VAR_RA_HARDCORE, '0')
        # @app.command('ttk::checkbutton', RA_HARDCORE_CHECK,
        #   text: translate('settings.ra_hardcore'),
        #   variable: VAR_RA_HARDCORE,
        #   command: proc { @mark_dirty.call })
        # @app.command(:pack, RA_HARDCORE_CHECK, side: :left)
      end

      def browse_bios
        path = @app.tcl_eval("tk_getOpenFile -filetypes {{{BIOS Files} {.bin}} {{All Files} *}}")
        return if path.to_s.strip.empty?

        FileUtils.mkdir_p(Config.bios_dir)
        dest = File.join(Config.bios_dir, File.basename(path))
        FileUtils.cp(path, dest) unless File.expand_path(path) == File.expand_path(dest)

        bios = Bios.new(path: dest)
        @app.set_variable(VAR_BIOS_PATH, bios.filename)
        update_status(bios)
        @mark_dirty.call
        emit(:bios_changed, filename: bios.filename)
      end

      def clear_bios
        @app.set_variable(VAR_BIOS_PATH, '')
        @app.command(BIOS_STATUS, :configure, text: translate('settings.bios_not_set'))
        @mark_dirty.call
        emit(:bios_changed, filename: nil)
      end

      def update_status(bios)
        text = if !bios.exists?
          translate('settings.bios_not_found')
        else
          bios.status_text
        end
        @app.command(BIOS_STATUS, :configure, text: text)
      end

      def apply_presenter_state
        return unless @presenter

        # Swap between editable ttk::entry and styled readonly tk::entry
        swap_cred_fields(@presenter.fields_state == :readonly)

        # Buttons (login/verify/logout/reset still use ttk)
        @app.command(RA_LOGIN_BTN,  :configure, state: @presenter.login_button_state)
        @app.command(RA_VERIFY_BTN, :configure, state: @presenter.verify_button_state)
        @app.command(RA_LOGOUT_BTN, :configure, state: @presenter.logout_button_state)
        @app.command(RA_RESET_BTN,  :configure, state: @presenter.reset_button_state)

        # Feedback label
        fb   = @presenter.feedback
        text = case fb[:key]
               when :empty         then ''
               when :not_logged_in then translate('settings.ra_not_logged_in')
               when :logged_in_as  then translate('settings.ra_logged_in_as', username: fb[:username].to_s)
               when :test_ok       then translate('settings.ra_test_ok')
               when :error         then fb[:message].to_s
               else ''
               end
        @app.command(RA_FEEDBACK_LABEL, :configure, text: text)

        # Keep Tcl variable in sync with presenter (e.g. after logout)
        @app.set_variable(VAR_RA_USERNAME, @presenter.username)
      end

      # Swap between editable ttk::entry widgets and gray readonly tk::entry widgets.
      # Uses pack -before to preserve visual order relative to the password label.
      def swap_cred_fields(readonly)
        pw_lbl = "#{FRAME}.ra_creds_row.pw_lbl"
        creds_row = "#{FRAME}.ra_creds_row"
        if readonly
          @app.tcl_eval("pack forget #{RA_USERNAME_ENTRY} #{RA_TOKEN_ENTRY}")
          @app.tcl_eval("pack #{RA_USERNAME_RO} -in #{creds_row} -side left -padx {0 10} -before #{pw_lbl}")
          @app.tcl_eval("pack #{RA_TOKEN_RO} -in #{creds_row} -side left")
        else
          @app.tcl_eval("pack forget #{RA_USERNAME_RO} #{RA_TOKEN_RO}")
          @app.tcl_eval("pack #{RA_USERNAME_ENTRY} -in #{creds_row} -side left -padx {0 10} -before #{pw_lbl}")
          @app.tcl_eval("pack #{RA_TOKEN_ENTRY} -in #{creds_row} -side left -after #{RA_USERNAME_ENTRY}")
          @app.command(RA_USERNAME_ENTRY, :configure, state: @presenter.fields_state)
          @app.command(RA_TOKEN_ENTRY,    :configure, state: @presenter.fields_state)
        end
      end

      def confirm_ra_reset
        answer = @app.tcl_eval(
          "tk_messageBox -parent #{Settings::Paths::TOP} " \
          "-type yesno -icon warning " \
          "-title {#{translate('settings.ra_reset_title')}} " \
          "-message {#{translate('settings.ra_reset_confirm')}}"
        )
        return unless answer == 'yes'

        @presenter&.username = ''
        @app.set_variable(VAR_RA_USERNAME, '')
        @app.set_variable(VAR_RA_PASSWORD, '')
        emit(:ra_logout)
        @mark_dirty.call
      end

    end
  end
end
