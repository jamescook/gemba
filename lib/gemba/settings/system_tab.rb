# frozen_string_literal: true

module Gemba
  module Settings
    class SystemTab
      include Locale::Translatable
      include BusEmitter

      FRAME         = "#{Paths::NB}.system"
      BIOS_ENTRY    = "#{FRAME}.bios_row.entry"
      BIOS_BROWSE   = "#{FRAME}.bios_row.browse"
      BIOS_CLEAR    = "#{FRAME}.bios_row.clear"
      BIOS_STATUS   = "#{FRAME}.bios_status"
      SKIP_BIOS_CHECK = "#{FRAME}.skip_row.check"

      VAR_BIOS_PATH = '::gemba_bios_path'
      VAR_SKIP_BIOS = '::gemba_skip_bios'

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
      end

      private

      def build_bios_section
        # Header label
        hdr = "#{FRAME}.bios_hdr"
        @app.command('ttk::label', hdr, text: translate('settings.bios_header'))
        @app.command(:pack, hdr, anchor: :w, padx: 10, pady: [15, 2])

        # Path row: readonly entry + Browse + Clear
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

        # Status label
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

    end
  end
end
