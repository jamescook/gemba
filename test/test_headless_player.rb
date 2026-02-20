# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"
require "tmpdir"

class TestHeadlessPlayer < Minitest::Test
  TEST_ROM = File.expand_path("fixtures/test.gba", __dir__)


  # -- Lifecycle ---------------------------------------------------------------

  def test_open_and_close
    player = Gemba::HeadlessPlayer.new(TEST_ROM)
    refute player.closed?
    player.close
    assert player.closed?
  end

  def test_double_close_is_safe
    player = Gemba::HeadlessPlayer.new(TEST_ROM)
    player.close
    player.close # should not raise
    assert player.closed?
  end

  def test_block_form
    result = Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      refute player.closed?
      :ok
    end
    assert_equal :ok, result
  end

  def test_block_form_closes_on_exception
    assert_raises(RuntimeError) do
      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        @ref = player
        raise "boom"
      end
    end
    assert @ref.closed?
  end

  # -- Stepping ----------------------------------------------------------------

  def test_step_single_frame
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.step # should not raise
    end
  end

  def test_step_multiple_frames
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.step(60) # should not raise
    end
  end

  def test_step_after_close_raises
    player = Gemba::HeadlessPlayer.new(TEST_ROM)
    player.close
    assert_raises(RuntimeError) { player.step }
  end

  # -- Input -------------------------------------------------------------------

  def test_press_and_release
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.press(Gemba::KEY_A | Gemba::KEY_START)
      player.step
      player.release_all
      player.step
    end
  end

  # -- Buffers -----------------------------------------------------------------

  def test_video_buffer_argb_size
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.step
      buf = player.video_buffer_argb
      assert_equal 240 * 160 * 4, buf.bytesize
    end
  end

  def test_audio_buffer_returns_data
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.step
      buf = player.audio_buffer
      assert_kind_of String, buf
    end
  end

  # -- Dimensions --------------------------------------------------------------

  def test_width_and_height
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      assert_equal 240, player.width
      assert_equal 160, player.height
    end
  end

  # -- ROM metadata ------------------------------------------------------------

  def test_title
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      assert_equal "GEMBATEST", player.title
    end
  end

  def test_game_code
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      assert_equal "AGB-BGBE", player.game_code
    end
  end

  def test_maker_code
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      assert_equal "01", player.maker_code
    end
  end

  def test_checksum
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      assert_kind_of Integer, player.checksum
    end
  end

  def test_platform
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      assert_equal "GBA", player.platform
    end
  end

  def test_rom_size
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      assert_operator player.rom_size, :>, 0
    end
  end

  # -- Save states -------------------------------------------------------------

  def test_save_and_load_state
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.ss1")

      Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
        player.step(10)
        assert player.save_state(path)
        assert File.exist?(path)

        player.step(60)
        assert player.load_state(path)
      end
    end
  end

  # -- Rewind ------------------------------------------------------------------

  def test_rewind_init_and_count
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.rewind_init(3)
      assert_equal 0, player.rewind_count

      player.step
      player.rewind_push
      assert_equal 1, player.rewind_count

      player.step
      player.rewind_push
      assert_equal 2, player.rewind_count
    end
  end

  def test_rewind_pop
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.rewind_init(5)
      player.step(10)
      player.rewind_push
      player.step(10)
      assert player.rewind_pop
      assert_equal 0, player.rewind_count
    end
  end

  def test_rewind_pop_empty_returns_false
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.rewind_init(3)
      refute player.rewind_pop
    end
  end

  def test_rewind_deinit
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      player.rewind_init(3)
      player.step
      player.rewind_push
      player.rewind_deinit
      assert_equal 0, player.rewind_count
    end
  end

  # -- BIOS loading -----------------------------------------------------------

  FAKE_BIOS = File.expand_path("fixtures/fake_bios.bin", __dir__)

  def test_bios_not_loaded_by_default
    Gemba::HeadlessPlayer.open(TEST_ROM) do |player|
      refute player.core.bios_loaded?
    end
  end

  def test_bios_loaded_when_path_given
    skip "fake_bios.bin not present" unless File.exist?(FAKE_BIOS)
    Gemba::HeadlessPlayer.open(TEST_ROM, bios_path: FAKE_BIOS) do |player|
      assert player.core.bios_loaded?
    end
  end
end
