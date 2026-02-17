# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/input_recorder"
require "tmpdir"

class TestInputReplayDeterminism < Minitest::Test
  PONG_ROM = File.expand_path("fixtures/pong.gba", __dir__)
  TEST_ROM = File.expand_path("fixtures/test.gba", __dir__)

# Record inputs against pong, then replay from anchor state.
  # Video buffer after replay must match the original recording frame-for-frame.
  def test_deterministic_replay
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "pong.gir")
      frames = 120 # ~2 seconds of gameplay

      # -- Phase 1: Record --
      final_video = nil
      Gemba::HeadlessPlayer.open(PONG_ROM) do |player|
        # Let the game boot for a few frames
        player.step(30)

        core = player.send(:instance_variable_get, :@core)
        rec = Gemba::InputRecorder.new(gir_path, core: core)
        rec.start

        # Play some inputs: Start to begin, then Up, A, idle, Down+B
        inputs = []
        inputs.concat([Gemba::KEY_START] * 30)
        inputs.concat([Gemba::KEY_UP] * 30)
        inputs.concat([Gemba::KEY_A] * 30)
        inputs.concat([0] * 30)
        inputs.concat([Gemba::KEY_DOWN | Gemba::KEY_B] * 30)

        inputs.each do |mask|
          rec.capture(mask)
          core.set_keys(mask)
          core.run_frame
        end

        rec.stop
        final_video = core.video_buffer_argb.dup
      end

      assert File.exist?(gir_path), ".gir file should exist"
      assert File.exist?(gir_path.sub(/\.gir\z/, '.state')), ".state file should exist"

      # -- Phase 2: Replay --
      replay_video = nil
      Gemba::HeadlessPlayer.open(PONG_ROM) do |player|
        player.replay(gir_path)
        replay_video = player.video_buffer_argb.dup
      end

      # -- Phase 3: Compare --
      assert_equal final_video.bytesize, replay_video.bytesize,
        "video buffer sizes should match"
      assert_equal final_video, replay_video,
        "video buffer after replay should be identical to recording"
    end
  end

  # Replay with the wrong ROM should raise ChecksumMismatch.
  def test_replay_wrong_rom_raises
    skip "test.gba fixture missing" unless File.exist?(TEST_ROM)

    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "pong.gir")

      # Record against pong
      Gemba::HeadlessPlayer.open(PONG_ROM) do |player|
        player.step(5)
        core = player.send(:instance_variable_get, :@core)
        rec = Gemba::InputRecorder.new(gir_path, core: core)
        rec.start
        rec.capture(0)
        rec.stop
      end

      # Try to replay against test.gba — wrong ROM
      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        assert_raises(Gemba::InputReplayer::ChecksumMismatch) do
          player.replay(gir_path)
        end
      end
    end
  end

  # Replay with block yields each frame.
  def test_replay_yields_frames
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "pong.gir")

      Gemba::HeadlessPlayer.open(PONG_ROM) do |player|
        player.step(5)
        core = player.send(:instance_variable_get, :@core)
        rec = Gemba::InputRecorder.new(gir_path, core: core)
        rec.start
        [0x001, 0x041, 0x000].each { |m| rec.capture(m) }
        rec.stop
      end

      collected = []
      Gemba::HeadlessPlayer.open(PONG_ROM) do |player|
        player.replay(gir_path) { |mask, idx| collected << [mask, idx] }
      end

      assert_equal [[0x001, 0], [0x041, 1], [0x000, 2]], collected
    end
  end
end
