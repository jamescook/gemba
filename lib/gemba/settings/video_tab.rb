# frozen_string_literal: true

require_relative "paths"

module Gemba
  module Settings
    class VideoTab
      include Locale::Translatable

      FRAME                  = "#{Paths::NB}.video"
      SCALE_COMBO            = "#{FRAME}.scale_row.scale_combo"
      TURBO_COMBO            = "#{FRAME}.turbo_row.turbo_combo"
      ASPECT_CHECK           = "#{FRAME}.aspect_row.aspect"
      SHOW_FPS_CHECK         = "#{FRAME}.fps_row.fps_check"
      TOAST_COMBO            = "#{FRAME}.toast_row.toast_combo"
      FILTER_COMBO           = "#{FRAME}.filter_row.filter_combo"
      INTEGER_SCALE_CHECK    = "#{FRAME}.intscale_row.intscale"
      COLOR_CORRECTION_CHECK = "#{FRAME}.colorcorr_row.colorcorr"
      FRAME_BLENDING_CHECK   = "#{FRAME}.frameblend_row.frameblend"
      REWIND_CHECK           = "#{FRAME}.rewind_row.rewind"

      VAR_SCALE            = '::mgba_scale'
      VAR_TURBO            = '::mgba_turbo'
      VAR_ASPECT_RATIO     = '::mgba_aspect_ratio'
      VAR_SHOW_FPS         = '::mgba_show_fps'
      VAR_TOAST_DURATION   = '::mgba_toast_duration'
      VAR_FILTER           = '::mgba_filter'
      VAR_INTEGER_SCALE    = '::mgba_integer_scale'
      VAR_COLOR_CORRECTION = '::mgba_color_correction'
      VAR_FRAME_BLENDING   = '::mgba_frame_blending'
      VAR_REWIND_ENABLED   = '::mgba_rewind_enabled'
      VAR_PAUSE_FOCUS      = '::gemba_pause_focus_loss'

      def initialize(app, callbacks:, tips:, mark_dirty:)
        @app = app
        @callbacks = callbacks
        @tips = tips
        @mark_dirty = mark_dirty
      end

      def build
        @app.command('ttk::frame', FRAME)
        @app.command(Paths::NB, 'add', FRAME, text: translate('settings.video'))

        build_scale_row
        build_turbo_row
        build_aspect_row
        build_show_fps_row
        build_pause_focus_row
        build_toast_row
        build_filter_row
        build_integer_scale_row
        build_color_correction_row
        build_frame_blending_row
        build_rewind_row
      end

      private

      def build_scale_row
        row = "#{FRAME}.scale_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: [15, 5])

        @app.command('ttk::label', "#{row}.lbl", text: translate('settings.window_scale'))
        @app.command(:pack, "#{row}.lbl", side: :left)

        @app.set_variable(VAR_SCALE, '3x')
        @app.command('ttk::combobox', SCALE_COMBO,
          textvariable: VAR_SCALE,
          values: Teek.make_list('1x', '2x', '3x', '4x'),
          state: :readonly,
          width: 5)
        @app.command(:pack, SCALE_COMBO, side: :right)

        @app.command(:bind, SCALE_COMBO, '<<ComboboxSelected>>',
          proc { |*|
            val = @app.get_variable(VAR_SCALE)
            scale = val.to_i
            if scale > 0
              @callbacks[:on_scale_change]&.call(scale)
              @mark_dirty.call
            end
          })
      end

      def build_turbo_row
        row = "#{FRAME}.turbo_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.command('ttk::label', "#{row}.lbl", text: translate('settings.turbo_speed'))
        @app.command(:pack, "#{row}.lbl", side: :left)
        @tips.register("#{row}.lbl", translate('settings.tip_turbo_speed'))

        @app.set_variable(VAR_TURBO, '2x')
        @app.command('ttk::combobox', TURBO_COMBO,
          textvariable: VAR_TURBO,
          values: Teek.make_list('2x', '3x', '4x', translate('settings.uncapped')),
          state: :readonly,
          width: 10)
        @app.command(:pack, TURBO_COMBO, side: :right)

        @app.command(:bind, TURBO_COMBO, '<<ComboboxSelected>>',
          proc { |*|
            val = @app.get_variable(VAR_TURBO)
            speed = val == translate('settings.uncapped') ? 0 : val.to_i
            @callbacks[:on_turbo_speed_change]&.call(speed)
            @mark_dirty.call
          })
      end

      def build_aspect_row
        row = "#{FRAME}.aspect_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_ASPECT_RATIO, '1')
        @app.command('ttk::checkbutton', ASPECT_CHECK,
          text: translate('settings.maintain_aspect'),
          variable: VAR_ASPECT_RATIO,
          command: proc { |*|
            keep = @app.get_variable(VAR_ASPECT_RATIO) == '1'
            @callbacks[:on_aspect_ratio_change]&.call(keep)
            @mark_dirty.call
          })
        @app.command(:pack, ASPECT_CHECK, side: :left)
      end

      def build_show_fps_row
        row = "#{FRAME}.fps_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_SHOW_FPS, '1')
        @app.command('ttk::checkbutton', SHOW_FPS_CHECK,
          text: translate('settings.show_fps'),
          variable: VAR_SHOW_FPS,
          command: proc { |*|
            show = @app.get_variable(VAR_SHOW_FPS) == '1'
            @callbacks[:on_show_fps_change]&.call(show)
            @mark_dirty.call
          })
        @app.command(:pack, SHOW_FPS_CHECK, side: :left)
      end

      def build_pause_focus_row
        row = "#{FRAME}.pause_focus_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_PAUSE_FOCUS, '1')
        @app.command('ttk::checkbutton', "#{row}.check",
          text: translate('settings.pause_on_focus_loss'),
          variable: VAR_PAUSE_FOCUS,
          command: proc { |*|
            val = @app.get_variable(VAR_PAUSE_FOCUS) == '1'
            @callbacks[:on_pause_on_focus_loss_change]&.call(val)
            @mark_dirty.call
          })
        @app.command(:pack, "#{row}.check", side: :left)
      end

      def build_toast_row
        row = "#{FRAME}.toast_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.command('ttk::label', "#{row}.lbl", text: translate('settings.toast_duration'))
        @app.command(:pack, "#{row}.lbl", side: :left)
        @tips.register("#{row}.lbl", translate('settings.tip_toast_duration'))

        @app.set_variable(VAR_TOAST_DURATION, '1.5s')
        @app.command('ttk::combobox', TOAST_COMBO,
          textvariable: VAR_TOAST_DURATION,
          values: Teek.make_list('0.5s', '1s', '1.5s', '2s', '3s', '5s', '10s'),
          state: :readonly,
          width: 5)
        @app.command(:pack, TOAST_COMBO, side: :right)

        @app.command(:bind, TOAST_COMBO, '<<ComboboxSelected>>',
          proc { |*|
            val = @app.get_variable(VAR_TOAST_DURATION)
            secs = val.to_f
            if secs > 0
              @callbacks[:on_toast_duration_change]&.call(secs)
              @mark_dirty.call
            end
          })
      end

      def build_filter_row
        row = "#{FRAME}.filter_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.command('ttk::label', "#{row}.lbl", text: translate('settings.pixel_filter'))
        @app.command(:pack, "#{row}.lbl", side: :left)
        @tips.register("#{row}.lbl", translate('settings.tip_pixel_filter'))

        @app.set_variable(VAR_FILTER, translate('settings.filter_nearest'))
        @app.command('ttk::combobox', FILTER_COMBO,
          textvariable: VAR_FILTER,
          values: Teek.make_list(translate('settings.filter_nearest'), translate('settings.filter_linear')),
          state: :readonly,
          width: 18)
        @app.command(:pack, FILTER_COMBO, side: :right)

        @app.command(:bind, FILTER_COMBO, '<<ComboboxSelected>>',
          proc { |*|
            val = @app.get_variable(VAR_FILTER)
            filter = val == translate('settings.filter_nearest') ? 'nearest' : 'linear'
            @callbacks[:on_filter_change]&.call(filter)
            @mark_dirty.call
          })
      end

      def build_integer_scale_row
        row = "#{FRAME}.intscale_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_INTEGER_SCALE, '0')
        @app.command('ttk::checkbutton', INTEGER_SCALE_CHECK,
          text: translate('settings.integer_scale'),
          variable: VAR_INTEGER_SCALE,
          command: proc { |*|
            enabled = @app.get_variable(VAR_INTEGER_SCALE) == '1'
            @callbacks[:on_integer_scale_change]&.call(enabled)
            @mark_dirty.call
          })
        @app.command(:pack, INTEGER_SCALE_CHECK, side: :left)
        tip = "#{row}.tip"
        @app.command('ttk::label', tip, text: '(?)')
        @app.command(:pack, tip, side: :left)
        @tips.register(tip, translate('settings.tip_integer_scale'))
      end

      def build_color_correction_row
        row = "#{FRAME}.colorcorr_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_COLOR_CORRECTION, '0')
        @app.command('ttk::checkbutton', COLOR_CORRECTION_CHECK,
          text: translate('settings.color_correction'),
          variable: VAR_COLOR_CORRECTION,
          command: proc { |*|
            enabled = @app.get_variable(VAR_COLOR_CORRECTION) == '1'
            @callbacks[:on_color_correction_change]&.call(enabled)
            @mark_dirty.call
          })
        @app.command(:pack, COLOR_CORRECTION_CHECK, side: :left)
        tip = "#{row}.tip"
        @app.command('ttk::label', tip, text: '(?)')
        @app.command(:pack, tip, side: :left)
        @tips.register(tip, translate('settings.tip_color_correction'))
      end

      def build_frame_blending_row
        row = "#{FRAME}.frameblend_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_FRAME_BLENDING, '0')
        @app.command('ttk::checkbutton', FRAME_BLENDING_CHECK,
          text: translate('settings.frame_blending'),
          variable: VAR_FRAME_BLENDING,
          command: proc { |*|
            enabled = @app.get_variable(VAR_FRAME_BLENDING) == '1'
            @callbacks[:on_frame_blending_change]&.call(enabled)
            @mark_dirty.call
          })
        @app.command(:pack, FRAME_BLENDING_CHECK, side: :left)
        tip = "#{row}.tip"
        @app.command('ttk::label', tip, text: '(?)')
        @app.command(:pack, tip, side: :left)
        @tips.register(tip, translate('settings.tip_frame_blending'))
      end

      def build_rewind_row
        row = "#{FRAME}.rewind_row"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 5)

        @app.set_variable(VAR_REWIND_ENABLED, '1')
        @app.command('ttk::checkbutton', REWIND_CHECK,
          text: translate('settings.rewind'),
          variable: VAR_REWIND_ENABLED,
          command: proc { |*|
            enabled = @app.get_variable(VAR_REWIND_ENABLED) == '1'
            @callbacks[:on_rewind_toggle]&.call(enabled)
            @mark_dirty.call
          })
        @app.command(:pack, REWIND_CHECK, side: :left)
        tip = "#{row}.tip"
        @app.command('ttk::label', tip, text: '(?)')
        @app.command(:pack, tip, side: :left)
        @tips.register(tip, translate('settings.tip_rewind'))
      end
    end
  end
end
