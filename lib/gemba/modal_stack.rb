# frozen_string_literal: true

module Gemba
  # Push/pop stack for modal child windows.
  #
  # Replaces ad-hoc @modal_child flag juggling with a proper stack so that
  # one modal can push another (e.g. Settings → Replay Player) and the
  # previous modal is automatically re-shown on pop.
  #
  # Windows must implement the ModalWindow protocol:
  #   show_modal(**args) — reveal the window (deiconify, grab, position)
  #   withdraw           — hide the window (release grab, withdraw — NO callback)
  #
  # @example
  #   stack = ModalStack.new(
  #     on_enter: ->(name) { pause_emulation },
  #     on_exit:  -> { unpause_emulation },
  #     on_focus_change: ->(name) { update_toast(name) },
  #   )
  #   stack.push(:settings, @settings_window, show_args: { tab: :video })
  #   stack.push(:replay, @replay_player)  # settings auto-withdrawn
  #   stack.pop  # replay closed, settings re-shown
  #   stack.pop  # settings closed, on_exit fired
  class ModalStack
    Entry = Data.define(:name, :window, :show_args)

    # @param on_enter [Proc] called with (name) when stack goes empty → non-empty
    # @param on_exit  [Proc] called when stack goes non-empty → empty
    # @param on_focus_change [Proc, nil] called with (name) whenever the top modal changes
    def initialize(on_enter:, on_exit:, on_focus_change: nil)
      @stack = []
      @on_enter = on_enter
      @on_exit  = on_exit
      @on_focus_change = on_focus_change
    end

    # @return [Boolean] true if any modal is open
    def active? = !@stack.empty?

    # @return [Symbol, nil] name of the topmost modal, or nil
    def current = @stack.last&.name

    # @return [Integer] number of modals on the stack
    def size = @stack.length

    # Push a modal onto the stack.
    #
    # If another modal is on top, it is withdrawn (without callback).
    # If the stack was empty, on_enter is fired (pause emulation, etc.).
    #
    # @param name [Symbol] identifier for the modal (e.g. :settings, :picker)
    # @param window [#show_modal, #withdraw] the modal window object
    # @param show_args [Hash] keyword arguments forwarded to window.show_modal
    def push(name, window, show_args: {})
      was_empty = @stack.empty?

      # Withdraw current top without firing its on_dismiss
      @stack.last&.window&.withdraw

      @stack.push(Entry.new(name: name, window: window, show_args: show_args))
      @on_enter.call(name) if was_empty
      @on_focus_change&.call(name)
      window.show_modal(**show_args)
    end

    # Pop the current modal off the stack.
    #
    # If the stack still has entries, the previous modal is re-shown.
    # If the stack is now empty, on_exit is fired (unpause emulation, etc.).
    def pop
      return unless (entry = @stack.pop)
      entry.window.withdraw

      if (prev = @stack.last)
        @on_focus_change&.call(prev.name)
        prev.window.show_modal(**prev.show_args)
      else
        @on_exit.call
      end
    end
  end
end
