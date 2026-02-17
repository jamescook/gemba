# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/input_recorder"
require "tmpdir"

class TestInputRecorder < Minitest::Test
  TEST_ROM = File.expand_path("fixtures/test.gba", __dir__)

  def setup
    skip "Run: ruby gemba/scripts/generate_test_rom.rb" unless File.exist?(TEST_ROM)
  end

  # -- Lifecycle ---------------------------------------------------------------

  def test_start_and_stop
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        rec = Gemba::InputRecorder.new(path, core: player.core)
        refute rec.recording?
        rec.start
        assert rec.recording?
        rec.capture(0)
        rec.stop
        refute rec.recording?
      end

      assert File.exist?(path)
    end
  end

  def test_double_start_raises
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        rec = Gemba::InputRecorder.new(path, core: player.core)
        rec.start
        assert_raises(RuntimeError) { rec.start }
        rec.stop
      end
    end
  end

  def test_stop_without_start_is_safe
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        rec = Gemba::InputRecorder.new(path, core: player.core)
        rec.stop # should not raise
      end
    end
  end

  # -- Anchor state ------------------------------------------------------------

  def test_anchor_state_created
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        player.step(10) # advance so state has content
        rec = Gemba::InputRecorder.new(path, core: player.core)
        rec.start
        rec.capture(0)
        rec.stop

        state_path = path.sub(/\.gir\z/, '.state')
        assert File.exist?(state_path), "anchor .state file should exist"
        assert_operator File.size(state_path), :>, 0
      end
    end
  end

  # -- Header ------------------------------------------------------------------

  def test_header_format
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        core = player.core
        rec = Gemba::InputRecorder.new(path, core: core)
        rec.start
        rec.capture(0)
        rec.stop

        lines = File.readlines(path)
        assert_match(/^# GEMBA INPUT RECORDING v1$/, lines[0])
        assert_match(/^# rom_checksum: \d+$/, lines[1])
        assert_match(/^# game_code: .+$/, lines[2])
        assert_match(/^# frame_count: \d+$/, lines[3])
        assert_match(/^# anchor_state: .+\.state$/, lines[4])
        assert_equal "---\n", lines[5]
      end
    end
  end

  def test_header_frame_count_updated_on_clean_stop
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        rec = Gemba::InputRecorder.new(path, core: player.core)
        rec.start
        5.times { |i| rec.capture(i) }
        rec.stop

        lines = File.readlines(path)
        assert_equal "# frame_count: 0000000005\n", lines[3]
      end
    end
  end

  # -- Bitmask data ------------------------------------------------------------

  def test_captures_correct_bitmasks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        rec = Gemba::InputRecorder.new(path, core: player.core)
        rec.start
        rec.capture(0x000)                          # nothing
        rec.capture(Gemba::KEY_A)                   # 0x001
        rec.capture(Gemba::KEY_UP | Gemba::KEY_A)   # 0x041
        rec.capture(0x3FF)                          # all buttons
        rec.stop

        lines = File.readlines(path)
        bitmasks = lines[6..] # after header (6 lines: 5 header + ---)
        assert_equal "000\n", bitmasks[0]
        assert_equal "001\n", bitmasks[1]
        assert_equal "041\n", bitmasks[2]
        assert_equal "3ff\n", bitmasks[3]
        assert_equal 4, rec.frame_count
      end
    end
  end

  def test_bitmask_masked_to_10_bits
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        rec = Gemba::InputRecorder.new(path, core: player.core)
        rec.start
        rec.capture(0xFFFF) # upper bits should be masked off
        rec.stop

        lines = File.readlines(path)
        assert_equal "3ff\n", lines[6]
      end
    end
  end

  # -- Flush behavior ----------------------------------------------------------

  def test_periodic_flush_writes_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.gir")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        rec = Gemba::InputRecorder.new(path, core: player.core)
        rec.start

        # Write exactly FLUSH_INTERVAL frames to trigger a flush
        Gemba::InputRecorder::FLUSH_INTERVAL.times { rec.capture(0) }

        # File should have data on disk even before stop
        size_before_stop = File.size(path)
        assert_operator size_before_stop, :>, 0

        rec.stop
      end
    end
  end
end
