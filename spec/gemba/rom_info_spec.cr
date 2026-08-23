require "../spec_helper"
require "file_utils"
require "../../src/gemba/rom_info"

private def with_tempdir(&)
  dir = File.tempname("rom_info_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private class FakeBackend < Gemba::BoxartFetcher::Backend
  def url_for(game_code : String) : String?
    nil
  end
end

# Guarantees app.destroy runs even if the block raises, preventing a
# leaked Tk window.
private def with_app(title : String, &)
  app = Tryst::App.new(title: title)
  begin
    yield app
  ensure
    app.destroy
  end
end

describe Gemba::RomInfo do
  before_each { Gemba::GameIndex.reset! }
  after_each { Gemba::GameIndex.reset! }

  it ".from_rom with no game_code/fetcher/overrides falls back to the library title, unofficial" do
    entry = Gemba::RomLibrary::Entry.new(title: "My Homebrew", path: "/roms/homebrew.gba",
      last_played: "", rom_id: "", game_code: "")
    info = Gemba::RomInfo.from_rom(entry)

    info.title.should eq "My Homebrew"
    info.platform.should eq "GBA"
    info.game_code.should eq ""
    info.rom_id.should eq ""
    info.has_official_entry.should be_false
    info.boxart_path.should be_nil
  end

  it ".from_rom prefers GameIndex's canonical name over the library's own title" do
    Gemba::GameIndex.preload!
    entry = Gemba::RomLibrary::Entry.new(title: "pokemon ruby (my dump)", path: "/roms/ruby.gba",
      last_played: "", rom_id: "AGB-AXVE-DEADBEEF", game_code: "AGB-AXVE")

    info = Gemba::RomInfo.from_rom(entry)

    info.title.should eq "Pokemon - Ruby Version (USA, Europe)"
    info.has_official_entry.should be_true
  end

  it ".from_rom with an unknown game_code keeps the library title and is not an official entry" do
    Gemba::GameIndex.preload!
    entry = Gemba::RomLibrary::Entry.new(title: "Mystery Cart", path: "/roms/mystery.gba",
      last_played: "", rom_id: "AGB-ZZZZ-DEADBEEF", game_code: "AGB-ZZZZ")

    info = Gemba::RomInfo.from_rom(entry)

    info.title.should eq "Mystery Cart"
    info.has_official_entry.should be_false
  end

  it "#boxart_path prefers a custom override over the auto-fetched cache" do
    with_tempdir do |dir|
      cache_dir = File.join(dir, "cache")
      Dir.mkdir_p(File.join(cache_dir, "AGB-AXVE"))
      File.write(File.join(cache_dir, "AGB-AXVE", "boxart.png"), "cached")

      overrides_path = File.join(dir, "rom_overrides.json")
      boxart_dir = File.join(dir, "boxart")
      Dir.mkdir_p(File.join(boxart_dir, "AGB-AXVE-DEADBEEF"))
      custom_path = File.join(boxart_dir, "AGB-AXVE-DEADBEEF", "custom.png")
      File.write(custom_path, "custom")
      File.write(overrides_path, %({"AGB-AXVE-DEADBEEF": {"custom_boxart": #{custom_path.to_json}}}))

      with_app("rom_info_1") do |app|
        fetcher = Gemba::BoxartFetcher.new(app, cache_dir, FakeBackend.new)
        overrides = Gemba::RomOverrides.new(overrides_path, boxart_dir: boxart_dir)
        entry = Gemba::RomLibrary::Entry.new(title: "Pokemon Ruby", path: "/roms/ruby.gba",
          last_played: "", rom_id: "AGB-AXVE-DEADBEEF", game_code: "AGB-AXVE")

        info = Gemba::RomInfo.from_rom(entry, fetcher: fetcher, overrides: overrides)

        info.custom_boxart_path.should eq custom_path
        info.cached_boxart_path.should eq fetcher.cached_path("AGB-AXVE")
        info.boxart_path.should eq custom_path
      end
    end
  end

  it "#boxart_path falls back to the cached path when there's no custom override" do
    with_tempdir do |dir|
      cache_dir = File.join(dir, "cache")
      Dir.mkdir_p(File.join(cache_dir, "AGB-AXVE"))
      File.write(File.join(cache_dir, "AGB-AXVE", "boxart.png"), "cached")

      with_app("rom_info_2") do |app|
        fetcher = Gemba::BoxartFetcher.new(app, cache_dir, FakeBackend.new)
        entry = Gemba::RomLibrary::Entry.new(title: "Pokemon Ruby", path: "/roms/ruby.gba",
          last_played: "", rom_id: "AGB-AXVE-DEADBEEF", game_code: "AGB-AXVE")

        info = Gemba::RomInfo.from_rom(entry, fetcher: fetcher)

        info.boxart_path.should eq fetcher.cached_path("AGB-AXVE")
      end
    end
  end

  it "#boxart_path returns nil when a previously-cached file has since been deleted" do
    with_tempdir do |dir|
      cache_dir = File.join(dir, "cache")
      Dir.mkdir_p(File.join(cache_dir, "AGB-AXVE"))
      cached_path = File.join(cache_dir, "AGB-AXVE", "boxart.png")
      File.write(cached_path, "cached")

      with_app("rom_info_3") do |app|
        fetcher = Gemba::BoxartFetcher.new(app, cache_dir, FakeBackend.new)
        entry = Gemba::RomLibrary::Entry.new(title: "Pokemon Ruby", path: "/roms/ruby.gba",
          last_played: "", rom_id: "AGB-AXVE-DEADBEEF", game_code: "AGB-AXVE")
        info = Gemba::RomInfo.from_rom(entry, fetcher: fetcher)

        File.delete(cached_path)
        info.boxart_path.should be_nil
      end
    end
  end
end
