# frozen_string_literal: true

require_relative "paths"

module Gemba
  module Settings
    class SaveStatesTab
      include Locale::Translatable

      FRAME        = "#{Paths::NB}.savestates"
      SLOT_COMBO   = "#{FRAME}.slot_row.slot_combo"
      BACKUP_CHECK = "#{FRAME}.backup_row.backup_check"
      OPEN_DIR_BTN = "#{FRAME}.dir_row.open_btn"

      VAR_QUICK_SLOT = '::mgba_quick_slot'
      VAR_BACKUP     = '::mgba_ss_backup'

      def initialize(app, callbacks:, tips:, mark_dirty:)
        @app = app
        @callbacks = callbacks
        @tips = tips
        @mark_dirty = mark_dirty
      end

      def build
        @app.command('ttk::frame', FRAME)
        @app.command(Paths::NB, 'add', FRAME, text: translate('settings.save_states'))

        # Quick Save Slot
        slot_row = "#{FRAME}.slot_row"
        @app.command('ttk::frame', slot_row)
        @app.command(:pack, slot_row, fill: :x, padx: 10, pady: [15, 5])

        @app.command('ttk::label', "#{slot_row}.lbl", text: translate('settings.quick_save_slot'))
        @app.command(:pack, "#{slot_row}.lbl", side: :left)

        slot_values = (1..10).map(&:to_s)
        @app.set_variable(VAR_QUICK_SLOT, '1')
        @app.command('ttk::combobox', SLOT_COMBO,
          textvariable: VAR_QUICK_SLOT,
          values: Teek.make_list(*slot_values),
          state: :readonly,
          width: 5)
        @app.command(:pack, SLOT_COMBO, side: :right)

        @app.command(:bind, SLOT_COMBO, '<<ComboboxSelected>>',
          proc { |*|
            val = @app.get_variable(VAR_QUICK_SLOT).to_i
            if val >= 1 && val <= 10
              @callbacks[:on_quick_slot_change]&.call(val)
              @mark_dirty.call
            end
          })

        # Backup rotation checkbox
        backup_row = "#{FRAME}.backup_row"
        @app.command('ttk::frame', backup_row)
        @app.command(:pack, backup_row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_BACKUP, '1')
        @app.command('ttk::checkbutton', BACKUP_CHECK,
          text: translate('settings.keep_backup'),
          variable: VAR_BACKUP,
          command: proc { |*|
            enabled = @app.get_variable(VAR_BACKUP) == '1'
            @callbacks[:on_backup_change]&.call(enabled)
            @mark_dirty.call
          })
        @app.command(:pack, BACKUP_CHECK, side: :left)
        backup_tip = "#{backup_row}.tip"
        @app.command('ttk::label', backup_tip, text: '(?)')
        @app.command(:pack, backup_tip, side: :left)
        @tips.register(backup_tip, translate('settings.tip_keep_backup'))

        # Open Config Folder button
        dir_row = "#{FRAME}.dir_row"
        @app.command('ttk::frame', dir_row)
        @app.command(:pack, dir_row, fill: :x, padx: 10, pady: [15, 5])

        @app.command('ttk::button', OPEN_DIR_BTN,
          text: translate('settings.open_config_folder'),
          command: proc { @callbacks[:on_open_config_dir]&.call })
        @app.command(:pack, OPEN_DIR_BTN, side: :left)
      end
    end
  end
end
