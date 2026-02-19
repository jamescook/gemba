# frozen_string_literal: true

require_relative 'frame_stack'

module Gemba
  # Pure Tk shell — creates the app window and hosts a FrameStack.
  #
  # MainWindow knows nothing about ROMs, emulation, menus, or config.
  # It provides geometry/title/fullscreen primitives that the AppController
  # drives. Its only structural contribution is the FrameStack, which
  # manages show/hide transitions to prevent visual flash (FOUC).
  class MainWindow
    attr_reader :app, :frame_stack

    def initialize
      @app = Teek::App.new
      @app.show
      @frame_stack = FrameStack.new
    end

    def set_title(title)
      @app.set_window_title(title)
    end

    def set_geometry(w, h)
      @app.set_window_geometry("#{w}x#{h}")
    end

    def set_aspect(numer, denom)
      @app.command(:wm, 'aspect', '.', numer, denom, numer, denom)
    end

    def set_minsize(w, h)
      @app.command(:wm, 'minsize', '.', w, h)
    end

    def reset_minsize
      @app.command(:wm, 'minsize', '.', 0, 0)
    end

    def reset_aspect_ratio
      @app.command(:wm, 'aspect', '.', '', '', '', '')
    end

    def set_timer_speed(ms)
      @app.interp.thread_timer_ms = ms
    end

    def fullscreen=(val)
      @app.command(:wm, 'attributes', '.', '-fullscreen', val ? 1 : 0)
    end

    def mainloop
      @app.mainloop
    end
  end
end
