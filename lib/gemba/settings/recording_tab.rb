# frozen_string_literal: true

require_relative "paths"

module Gemba
  module Settings
    class RecordingTab
      include Locale::Translatable

      FRAME              = "#{Paths::NB}.recording"
      COMPRESSION_COMBO  = "#{FRAME}.comp_row.comp_combo"
      OPEN_DIR_BTN       = "#{FRAME}.dir_row.open_btn"

      VAR_COMPRESSION = '::mgba_rec_compression'

      def initialize(app, callbacks:, tips:, mark_dirty:)
        @app = app
        @callbacks = callbacks
        @tips = tips
        @mark_dirty = mark_dirty
      end

      def build
        @app.command('ttk::frame', FRAME)
        @app.command(Paths::NB, 'add', FRAME, text: translate('settings.recording'))

        # Compression level
        comp_row = "#{FRAME}.comp_row"
        @app.command('ttk::frame', comp_row)
        @app.command(:pack, comp_row, fill: :x, padx: 10, pady: [15, 5])

        @app.command('ttk::label', "#{comp_row}.lbl", text: translate('settings.recording_compression'))
        @app.command(:pack, "#{comp_row}.lbl", side: :left)

        comp_tip = "#{comp_row}.tip"
        @app.command('ttk::label', comp_tip, text: '(?)')
        @app.command(:pack, comp_tip, side: :left)
        @tips.register(comp_tip, translate('settings.tip_recording_compression'))

        comp_values = (1..9).map(&:to_s)
        @app.set_variable(VAR_COMPRESSION, '1')
        @app.command('ttk::combobox', COMPRESSION_COMBO,
          textvariable: VAR_COMPRESSION,
          values: Teek.make_list(*comp_values),
          state: :readonly,
          width: 5)
        @app.command(:pack, COMPRESSION_COMBO, side: :right)

        @app.command(:bind, COMPRESSION_COMBO, '<<ComboboxSelected>>',
          proc { |*|
            val = @app.get_variable(VAR_COMPRESSION).to_i
            if val >= 1 && val <= 9
              @callbacks[:on_compression_change]&.call(val)
              @mark_dirty.call
            end
          })

        # Open Recordings Folder button
        dir_row = "#{FRAME}.dir_row"
        @app.command('ttk::frame', dir_row)
        @app.command(:pack, dir_row, fill: :x, padx: 10, pady: [15, 5])

        @app.command('ttk::button', OPEN_DIR_BTN,
          text: translate('settings.open_recordings_folder'),
          command: proc { @callbacks[:on_open_recordings_dir]&.call })
        @app.command(:pack, OPEN_DIR_BTN, side: :left)
      end
    end
  end
end
