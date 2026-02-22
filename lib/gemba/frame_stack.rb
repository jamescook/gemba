# frozen_string_literal: true

module Gemba
  # Push/pop stack for content frames inside the main window.
  #
  # Mirrors the ModalStack pattern. When a new frame is pushed, the
  # previous frame is hidden and the new one is shown. Popping reverses
  # the transition.
  #
  # Frames must implement the FrameStack protocol:
  #   show     — pack/display the frame
  #   hide     — unpack/remove the frame from view
  #   cleanup  — release resources (SDL2, etc.)
  #
  # @example
  #   stack = FrameStack.new
  #   stack.push(:picker, game_picker_frame)
  #   stack.push(:emulator, emulator_frame)  # picker auto-hidden
  #   stack.pop  # emulator hidden, picker re-shown
  class FrameStack
    Entry = Data.define(:name, :frame)

    def initialize
      @stack = []
    end

    # @return [Boolean] true if any frame is on the stack
    def active? = !@stack.empty?

    # @return [Symbol, nil] name of the topmost frame
    def current = @stack.last&.name

    # @return [Object, nil] the topmost frame object
    def current_frame = @stack.last&.frame

    # @return [Integer] number of frames on the stack
    def size = @stack.length

    # Push a frame onto the stack.
    #
    # The previous frame (if any) is hidden before the new one is shown.
    #
    # @param name [Symbol] identifier (e.g. :picker, :emulator)
    # @param frame [#show, #hide] the frame object
    def push(name, frame)
      @stack.last&.frame&.hide
      @stack.push(Entry.new(name: name, frame: frame))
      frame.show
    end

    # Replace the current frame in-place without changing the stack depth.
    #
    # The existing frame is hidden; the new one is shown under the same name.
    def replace_current(frame)
      return unless (entry = @stack.last)
      entry.frame.hide
      @stack[-1] = Entry.new(name: entry.name, frame: frame)
      frame.show
    end

    # Pop the current frame off the stack.
    #
    # The popped frame is hidden. If there's a previous frame, it is re-shown.
    def pop
      return unless (entry = @stack.pop)
      entry.frame.hide
      @stack.last&.frame&.show
    end
  end
end
