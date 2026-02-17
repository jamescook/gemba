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
# Capture a screenshot of the entire xvfb display.
# Saved to /app/coverage/ so it's accessible on the host via the volume mount.
def xvfb_screenshot(name = "debug")
  return unless ENV['DISPLAY']
  dir = "/app/test/screenshots"
  Dir.mkdir(dir) unless File.directory?(dir)
  path = "#{dir}/#{name}.png"
  system("import", "-window", "root", path)
  $stderr.puts "Screenshot saved: #{path}"
end

# Polls until the SDL2 window has INPUT_FOCUS, then yields.
# Under xvfb focus may take a moment to arrive after window creation.
# Falls back to xdotool to force focus if polling alone doesn't work.
def poll_until_focused(player, timeout_ms: 2_000, &block)
  app = player.app
  renderer = player.viewport.renderer
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_ms / 1000.0
  tried_xdotool = false
  check = proc do
    if renderer.input_focus?
      block.call
    elsif Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      xvfb_screenshot("no_focus")
      $stderr.puts "FAIL: window never got INPUT_FOCUS within #{timeout_ms}ms (screenshot: test/screenshots/no_focus.png)"
      exit 1
    else
      # After 500ms of polling, try xdotool to force focus (only in CI/Docker)
      if !tried_xdotool && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline - (timeout_ms / 1000.0) + 0.5
        tried_xdotool = true
        if ENV['DISPLAY'] # xvfb / X11 only
          system("xdotool search --name mGBA windowactivate --sync 2>/dev/null")
        end
      end
      app.after(50, &check)
    end
  end
  app.after(50, &check)
end

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
