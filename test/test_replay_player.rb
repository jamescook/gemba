# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestReplayPlayer < Minitest::Test
  include TeekTestHelper

  PONG_ROM = File.expand_path("fixtures/pong.gba", __dir__)

  # Generate a short .gir fixture for all GUI tests.
  # Uses HeadlessPlayer + InputRecorder to record 60 frames of pong.
  def self.gir_fixture_dir
    @gir_fixture_dir ||= begin
      require "tmpdir"
      dir = Dir.mktmpdir("gemba_replay_test")
      at_exit { FileUtils.rm_rf(dir) }

      require "gemba/headless"
      require "gemba/input_recorder"

      gir_path = File.join(dir, "pong_test.gir")
      Gemba::HeadlessPlayer.open(PONG_ROM) do |player|
        player.step(10)
        core = player.send(:instance_variable_get, :@core)
        rec = Gemba::InputRecorder.new(gir_path, core: core, rom_path: PONG_ROM)
        rec.start
        60.times do |i|
          mask = i < 30 ? Gemba::KEY_START : 0
          rec.capture(mask)
          core.set_keys(mask)
          core.run_frame
        end
        rec.stop
      end

      dir
    end
  end

  def gir_path
    File.join(self.class.gir_fixture_dir, "pong_test.gir")
  end

  # ReplayPlayer opens a window, plays frames, then exits cleanly.
  def test_replay_exits_cleanly
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) { rp.running = false }

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer should exit cleanly\n#{output.join("\n")}"
  end

  # After replay ends (60 frames), player should pause on last frame.
  def test_replay_pauses_on_end
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) do
        check = proc do
          if rp.replay_ended?
            unless rp.paused?
              $stderr.puts "FAIL: replay ended but not paused"
              exit 1
            end
            rp.running = false
          else
            app.after(100, &check)
          end
        end
        app.after(100, &check)
      end

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer should pause on replay end\n#{output.join("\n")}"
  end

  # Fullscreen toggle (F11 twice) should not hang.
  def test_fullscreen_toggle
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) do
        vp = rp.viewport
        frame = vp.frame.path

        app.tcl_eval("focus -force \#{frame}")
        app.command(:event, 'generate', frame, '<KeyPress>', keysym: 'F11')
        app.update

        app.after(50) do
          app.command(:event, 'generate', frame, '<KeyPress>', keysym: 'F11')
          app.update
          app.after(50) { rp.running = false }
        end
      end

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer fullscreen toggle should not hang\n#{output.join("\n")}"
  end

  # Fast-forward toggle (Tab) should not hang.
  def test_fast_forward_toggle
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) do
        vp = rp.viewport
        frame = vp.frame.path

        app.tcl_eval("focus -force \#{frame}")
        app.command(:event, 'generate', frame, '<KeyPress>', keysym: 'Tab')
        app.update

        app.after(200) do
          app.tcl_eval("focus -force \#{frame}")
          app.command(:event, 'generate', frame, '<KeyPress>', keysym: 'Tab')
          app.update
          app.after(50) { rp.running = false }
        end
      end

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer fast-forward toggle should not hang\n#{output.join("\n")}"
  end

  # Pause via public method, verify predicate.
  def test_pause_via_method
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) do
        app.after(100) do
          rp.pause
          unless rp.paused?
            $stderr.puts "FAIL: pause method should set paused?"
            exit 1
          end

          rp.resume
          if rp.paused?
            $stderr.puts "FAIL: resume should clear paused?"
            exit 1
          end

          rp.running = false
        end
      end

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer pause/resume methods should work\n#{output.join("\n")}"
  end

  # Pressing P should toggle pause via hotkey.
  def test_pause_hotkey
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) do
        vp = rp.viewport
        frame = vp.frame.path

        app.after(200) do
          app.tcl_eval("focus -force \#{frame}")
          app.command(:event, 'generate', frame, '<KeyPress>', keysym: 'p')
          app.update

          app.after(200) do
            unless rp.paused?
              $stderr.puts "FAIL: P should pause"
              exit 1
            end
            rp.running = false
          end
        end
      end

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer P hotkey should toggle pause\n#{output.join("\n")}"
  end

  # Escape should exit (when not fullscreen).
  def test_escape_exits
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) do
        vp = rp.viewport
        frame = vp.frame.path

        app.tcl_eval("focus -force \#{frame}")
        app.command(:event, 'generate', frame, '<KeyPress>', keysym: 'Escape')
      end

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer Escape should exit\n#{output.join("\n")}"
  end

  # frame_index should advance during replay.
  def test_frame_index_advances
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      rp = Gemba::ReplayPlayer.new("#{gir_path}")
      app = rp.app

      poll_until_ready(rp) do
        app.after(500) do
          idx = rp.frame_index
          if idx <= 0
            $stderr.puts "FAIL: frame_index should advance, got \#{idx}"
            exit 1
          end
          rp.running = false
        end
      end

      rp.run
    RUBY

    success, stdout, stderr, _status = tk_subprocess(code, timeout: 10)

    output = []
    output << "STDOUT:\n#{stdout}" unless stdout.empty?
    output << "STDERR:\n#{stderr}" unless stderr.empty?

    assert success, "ReplayPlayer frame_index should advance\n#{output.join("\n")}"
  end
end
