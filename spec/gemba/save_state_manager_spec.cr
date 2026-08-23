require "../spec_helper"
require "file_utils"

private SPACE_BLAST_ROM = File.join(__DIR__, "..", "fixtures", "space_blast.gba")

private def with_tempdir(&)
  dir = File.tempname("gemba_save_state_manager_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::SaveStateManager do
  it ".state_dir_for names the directory after the ROM's game code and checksum" do
    core = Gemba::Core.new(SPACE_BLAST_ROM)
    dir = Gemba::SaveStateManager.state_dir_for(core)
    dir.should end_with("#{core.game_code}-#{core.checksum.to_s(16).rjust(8, '0').upcase}")
    core.destroy
  end

  it "#save_state then #load_state round-trips real emulator state" do
    with_tempdir do |tmp|
      core = Gemba::Core.new(SPACE_BLAST_ROM)
      manager = Gemba::SaveStateManager.new(core, state_dir: tmp, debounce: 0.seconds)

      10.times { core.run_frame }
      ok, message = manager.save_state(core, 1)
      ok.should be_true
      message.should contain "slot 1"
      File.exists?(manager.state_path(1)).should be_true

      core.run_frame
      frame_after_save = core.video_buffer.dup
      20.times { core.run_frame }

      ok, _ = manager.load_state(core, 1)
      ok.should be_true
      core.run_frame
      core.video_buffer.should eq frame_after_save

      core.destroy
    end
  end

  it "#load_state fails cleanly when the slot has nothing saved" do
    with_tempdir do |tmp|
      core = Gemba::Core.new(SPACE_BLAST_ROM)
      manager = Gemba::SaveStateManager.new(core, state_dir: tmp)

      ok, message = manager.load_state(core, 5)
      ok.should be_false
      message.should contain "slot 5"

      core.destroy
    end
  end

  it "#save_state debounces rapid repeated saves" do
    with_tempdir do |tmp|
      core = Gemba::Core.new(SPACE_BLAST_ROM)
      manager = Gemba::SaveStateManager.new(core, state_dir: tmp, debounce: 10.seconds)

      core.run_frame
      manager.save_state(core, 1).first.should be_true
      manager.save_state(core, 1).first.should be_false

      core.destroy
    end
  end

  it "#save_state rotates the previous save to .bak when backup? is true" do
    with_tempdir do |tmp|
      core = Gemba::Core.new(SPACE_BLAST_ROM)
      manager = Gemba::SaveStateManager.new(core, state_dir: tmp, debounce: 0.seconds)

      core.run_frame
      manager.save_state(core, 1)
      first_save = File.read(manager.state_path(1))

      core.run_frame
      manager.save_state(core, 1)

      File.exists?("#{manager.state_path(1)}.bak").should be_true
      File.read("#{manager.state_path(1)}.bak").should eq first_save

      core.destroy
    end
  end

  it "#quick_save/#quick_load use quick_save_slot" do
    with_tempdir do |tmp|
      core = Gemba::Core.new(SPACE_BLAST_ROM)
      manager = Gemba::SaveStateManager.new(core, state_dir: tmp, quick_save_slot: 7, debounce: 0.seconds)

      core.run_frame
      manager.quick_save(core).first.should be_true
      File.exists?(manager.state_path(7)).should be_true

      ok, _ = manager.quick_load(core)
      ok.should be_true

      core.destroy
    end
  end
end
