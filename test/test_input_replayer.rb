# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "gemba/headless"
require "tmpdir"

class TestInputReplayer < Minitest::Test
  TEST_ROM = File.expand_path("fixtures/test.gba", __dir__)


  # -- Round-trip: record then replay ------------------------------------------

  def test_round_trip_frame_count
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      record(gir_path, [0x000, 0x001, 0x041, 0x3FF])

      replayer = Gemba::InputReplayer.new(gir_path)
      assert_equal 4, replayer.frame_count
    end
  end

  def test_round_trip_bitmasks
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      inputs = [0x000, 0x001, 0x041, 0x3FF]
      record(gir_path, inputs)

      replayer = Gemba::InputReplayer.new(gir_path)
      inputs.each_with_index do |expected, i|
        assert_equal expected, replayer.bitmask_at(i), "frame #{i}"
      end
    end
  end

  def test_each_bitmask
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      inputs = [0x001, 0x041, 0x000]
      record(gir_path, inputs)

      replayer = Gemba::InputReplayer.new(gir_path)
      collected = []
      replayer.each_bitmask { |mask, idx| collected << [mask, idx] }

      assert_equal [[0x001, 0], [0x041, 1], [0x000, 2]], collected
    end
  end

  # -- Header parsing ----------------------------------------------------------

  def test_rom_checksum_parsed
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      record(gir_path, [0])

      replayer = Gemba::InputReplayer.new(gir_path)
      assert_kind_of Integer, replayer.rom_checksum
      assert_operator replayer.rom_checksum, :>, 0
    end
  end

  def test_game_code_parsed
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      record(gir_path, [0])

      replayer = Gemba::InputReplayer.new(gir_path)
      assert_equal "AGB-BGBE", replayer.game_code
    end
  end

  def test_anchor_state_path
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      record(gir_path, [0])

      replayer = Gemba::InputReplayer.new(gir_path)
      expected = File.join(dir, "test.state")
      assert_equal expected, replayer.anchor_state_path
      assert File.exist?(replayer.anchor_state_path)
    end
  end

  # -- Validation --------------------------------------------------------------

  def test_validate_passes_with_matching_rom
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      record(gir_path, [0])

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        replayer = Gemba::InputReplayer.new(gir_path)
        replayer.validate!(player.core)
        # should not raise
      end
    end
  end

  def test_validate_raises_on_checksum_mismatch
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      # Write a fake .gir with a bogus checksum
      File.write(gir_path, <<~GIR)
        # GEMBA INPUT RECORDING v1
        # rom_checksum: 99999
        # game_code: FAKE
        # frame_count: 1
        # anchor_state: test.state
        ---
        000
      GIR

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        replayer = Gemba::InputReplayer.new(gir_path)
        assert_raises(Gemba::InputReplayer::ChecksumMismatch) do
          replayer.validate!(player.core)
        end
      end
    end
  end

  # -- Crash resilience --------------------------------------------------------

  def test_truncated_file_loads_available_frames
    Dir.mktmpdir do |dir|
      gir_path = File.join(dir, "test.gir")
      # Simulate a crash: header says 0 frames but body has 3
      File.write(gir_path, <<~GIR)
        # GEMBA INPUT RECORDING v1
        # rom_checksum: 12345
        # game_code: TEST
        # frame_count: 0
        # anchor_state: test.state
        ---
        001
        041
        000
      GIR

      replayer = Gemba::InputReplayer.new(gir_path)
      assert_equal 3, replayer.frame_count
      assert_equal 0x001, replayer.bitmask_at(0)
      assert_equal 0x041, replayer.bitmask_at(1)
      assert_equal 0x000, replayer.bitmask_at(2)
    end
  end

  private

  def record(gir_path, bitmasks)
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.step(5) # advance a few frames for meaningful state
      core = player.core
      rec = Gemba::InputRecorder.new(gir_path, core: core)
      rec.start
      bitmasks.each { |m| rec.capture(m) }
      rec.stop
    end
  end
end
