require "tryst/ui"

module Gemba
  # Push/pop stack for modal child windows - direct port of ruby's
  # lib/gemba/modal_stack.rb, built on Tryst::UI::Handle's own #show/
  # #hide rather than raw wm calls: a ui.window declared modal: true
  # already grabs input and focuses itself on #show and releases the
  # grab on #hide (see Handle#show/#hide), so there's no separate grab/
  # focus bookkeeping left for this class to do - just which one window
  # is on top.
  #
  # @example
  #   stack = ModalStack.new(
  #     on_enter: ->(name : Symbol) { pause_emulation },
  #     on_exit:  -> { unpause_emulation },
  #   )
  #   stack.push(:settings, settings_window_handle)
  #   stack.push(:rom_info, rom_info_handle)  # settings auto-hidden
  #   stack.pop  # rom_info closed, settings re-shown
  #   stack.pop  # settings closed, on_exit fired
  class ModalStack
    private record Entry, name : Symbol, handle : Tryst::UI::Handle

    def initialize(@on_enter : Symbol -> Nil, @on_exit : -> Nil,
                   @on_focus_change : (Symbol -> Nil)? = nil)
      @stack = [] of Entry
    end

    def active? : Bool
      !@stack.empty?
    end

    def current : Symbol?
      @stack.last?.try(&.name)
    end

    def size : Int32
      @stack.size
    end

    # If another modal is on top, it's hidden (without triggering its own
    # dismiss handling). If the stack was empty, on_enter fires first.
    #
    # auto_close: true (the default) wires the window's own close button
    # to #pop, via Handle#on_close. Without it, Tk's default
    # WM_DELETE_WINDOW behavior applies instead - it destroys the
    # toplevel outright (see Window#on_close's own doc comment), which
    # both destroys a window meant to be reused and leaves this stack
    # thinking it's still active forever after.
    #
    # Wired on every #push rather than once ever: Handle#on_close
    # REPLACES whatever was registered before rather than stacking
    # handlers, so re-wiring the same handle on a later #push (e.g. the
    # settings window, reopened many times across a session) is harmless
    # and keeps this simple.
    #
    # Pass false for full manual control - e.g. a confirmation dialog
    # before actually closing - and wire the window's own #on_close
    # yourself; call #pop from it if this stack should still unwind.
    def push(name : Symbol, handle : Tryst::UI::Handle, auto_close : Bool = true) : Nil
      was_empty = @stack.empty?
      @stack.last?.try(&.handle.hide)

      @stack << Entry.new(name, handle)
      handle.on_close { |_args, _signal| pop } if auto_close
      @on_enter.call(name) if was_empty
      @on_focus_change.try(&.call(name))
      handle.show
    end

    # If a previous modal remains, it's re-shown. If the stack is now
    # empty, on_exit fires.
    def pop : Nil
      return unless entry = @stack.pop?

      entry.handle.hide

      if prev = @stack.last?
        @on_focus_change.try(&.call(prev.name))
        prev.handle.show
      else
        @on_exit.call
      end
    end
  end
end
