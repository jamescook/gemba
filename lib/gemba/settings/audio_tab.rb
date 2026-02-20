# frozen_string_literal: true


module Gemba
  module Settings
    class AudioTab
      include Locale::Translatable
      include BusEmitter

      FRAME        = "#{Paths::NB}.audio"
      VOLUME_SCALE = "#{FRAME}.vol_row.vol_scale"
      MUTE_CHECK   = "#{FRAME}.mute_row.mute"

      VAR_VOLUME = '::mgba_volume'
      VAR_MUTE   = '::mgba_mute'

      def initialize(app, tips:, mark_dirty:)
        @app = app
        @mark_dirty = mark_dirty
      end

      def load_from_config(config)
        @app.set_variable(VAR_VOLUME, config.volume.to_s)
        @app.command(@vol_val_label, 'configure', text: "#{config.volume}%")
        @app.set_variable(VAR_MUTE, config.muted? ? '1' : '0')
      end

      def build
        @app.command('ttk::frame', FRAME)
        @app.command(Paths::NB, 'add', FRAME, text: translate('settings.audio'))

        # Volume slider
        vol_row = "#{FRAME}.vol_row"
        @app.command('ttk::frame', vol_row)
        @app.command(:pack, vol_row, fill: :x, padx: 10, pady: [15, 5])

        @app.command('ttk::label', "#{vol_row}.lbl", text: translate('settings.volume'))
        @app.command(:pack, "#{vol_row}.lbl", side: :left)

        @vol_val_label = "#{vol_row}.vol_label"
        @app.command('ttk::label', @vol_val_label, text: '100%', width: 5)
        @app.command(:pack, @vol_val_label, side: :right)

        @app.set_variable(VAR_VOLUME, '100')
        @app.command('ttk::scale', VOLUME_SCALE,
          orient: :horizontal,
          from: 0,
          to: 100,
          length: 150,
          variable: VAR_VOLUME,
          command: proc { |v, *|
            pct = v.to_f.round
            @app.command(@vol_val_label, 'configure', text: "#{pct}%")
            emit(:volume_changed, pct / 100.0)
            @mark_dirty.call
          })
        @app.command(:pack, VOLUME_SCALE, side: :right, padx: [5, 5])

        # Mute checkbox
        mute_row = "#{FRAME}.mute_row"
        @app.command('ttk::frame', mute_row)
        @app.command(:pack, mute_row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_MUTE, '0')
        @app.command('ttk::checkbutton', MUTE_CHECK,
          text: translate('settings.mute'),
          variable: VAR_MUTE,
          command: proc { |*|
            muted = @app.get_variable(VAR_MUTE) == '1'
            emit(:mute_changed, muted)
            @mark_dirty.call
          })
        @app.command(:pack, MUTE_CHECK, side: :left)
      end
    end
  end
end
