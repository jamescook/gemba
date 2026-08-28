module Gemba
  # Bookkeeping for pauses gemba issues on the user's behalf - a modal
  # dialog opening, the app losing focus, a menu being posted. Several
  # can overlap (open Settings, switch away, switch back), so a plain
  # boolean is wrong: coming back to a still-open Settings window must
  # not resume the game.
  #
  # Every cause holds a named reason and releases it again. Only the
  # first hold pauses and only the last release resumes, and neither
  # happens at all if the user had already paused manually before the
  # first hold - an auto-resume must never undo an explicit pause.
  #
  # Pure bookkeeping: it never touches the emulator itself, it answers
  # whether the caller should. That keeps the overlap rules testable
  # without a worker, a Core or a window.
  class AutoPause
    getter reasons = Set(Symbol).new

    @user_paused = false

    # paused_now: whether emulation is paused right now, read only when
    # this is the first reason - a later hold can't tell a user pause
    # apart from the auto-pause already in effect.
    #
    # Returns true if the caller should now pause.
    def hold(reason : Symbol, paused_now : Bool) : Bool
      @user_paused = paused_now if @reasons.empty?
      return false unless @reasons.add?(reason)

      @reasons.size == 1 && !@user_paused
    end

    # Returns true if the caller should now resume. Releasing a reason
    # that was never held is a no-op, so a cause that fires its release
    # twice (a Deactivate with no matching Activate, say) is harmless.
    def release(reason : Symbol) : Bool
      return false unless @reasons.delete(reason)

      @reasons.empty? && !@user_paused
    end

    def held?(reason : Symbol) : Bool
      @reasons.includes?(reason)
    end

    def active? : Bool
      !@reasons.empty?
    end
  end
end
