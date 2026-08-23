module Gemba
  # Crystal has real interfaces, unlike ruby's duck-typing, so the
  # FrameStack entry contract is a module instead of a doc comment.
  module Frame
    abstract def show : Nil
    abstract def hide : Nil
    abstract def cleanup : Nil
  end

  # Push/pop stack for content frames inside the main window.
  class FrameStack
    private record Entry, name : Symbol, frame : Frame

    def initialize
      @stack = [] of Entry
    end

    def active? : Bool
      !@stack.empty?
    end

    def current : Symbol?
      @stack.last?.try(&.name)
    end

    def current_frame : Frame?
      @stack.last?.try(&.frame)
    end

    def size : Int32
      @stack.size
    end

    def push(name : Symbol, frame : Frame) : Nil
      @stack.last?.try(&.frame.hide)
      @stack << Entry.new(name, frame)
      frame.show
    end

    # Replaces the current frame in place without changing stack depth
    # (e.g. switching picker view without disturbing whatever's beneath).
    def replace_current(frame : Frame) : Nil
      return unless entry = @stack.last?

      entry.frame.hide
      @stack[-1] = Entry.new(entry.name, frame)
      frame.show
    end

    def pop : Nil
      return unless entry = @stack.pop?

      entry.frame.hide
      @stack.last?.try(&.frame.show)
    end
  end
end
