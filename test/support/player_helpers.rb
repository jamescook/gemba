# frozen_string_literal: true

# == xvfb gotcha: focus & key events ==
#
# Under xvfb, `event generate <widget> <KeyPress>` only fires bindings
# when the widget has focus. The first key event after poll_until_ready
# usually works, but inside nested `app.after` callbacks focus can drift.
# If a second (or later) key event silently does nothing, add:
#
#   app.tcl_eval("focus -force #{frame}")
#
# before the `event generate` call. See test_recording_toggle for an example.

# Polls until the Player is ready, then yields the block.
#
# When a ROM is loaded, SDL2 initializes lazily on first load_rom call.
# poll_until_ready waits for sdl2_ready? in that case. When no ROM is
# loaded (e.g. drop target tests), the player is immediately interactive
# so we just defer one tick for the event loop to settle.
#
# @param player [Gemba::Player]
# @param timeout_ms [Integer] max wait before aborting (default 5s)
def poll_until_ready(player, timeout_ms: 5_000, &block)
  app = player.app
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_ms / 1000.0
  check = proc do
    if player.ready?
      block.call
    elsif Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      $stderr.puts "FAIL: Player not ready within #{timeout_ms}ms"
      exit 1
    else
      app.after(50, &check)
    end
  end
  app.after(50, &check)
end
