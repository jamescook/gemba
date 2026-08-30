require "../spec_helper"
require "file_utils"

private alias Achievement = Gemba::Achievements::Achievement

private ALPHA = "AGB-ALPH-11111111"
private BETA  = "AGB-BETA-22222222"

private record Built, app : Tryst::App, window : Gemba::AchievementsWindow, config : Gemba::Config, cache_dir : String

# A two-game library, the window declared the way MainWindow declares
# it, and the window's own content added after run_async. The cache
# dir is a subdirectory of the tempdir that nothing creates until a
# test writes to it.
private def build(dir : String, title : String) : Built
  library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
  library.remember("Alpha Quest", "/roms/alpha.gba", "2026-01-01T00:00:00Z")
  library.update_identity("/roms/alpha.gba", "AGB-ALPH", 0x11111111_u32)
  library.remember("Beta Blast", "/roms/beta.gba", "2026-01-02T00:00:00Z")
  library.update_identity("/roms/beta.gba", "AGB-BETA", 0x22222222_u32)
  config = Gemba::Config.new(File.join(dir, "settings.json"))

  session = Tryst::UI::Session.new(title: title)
  handle = session.window(:gemba_achievements, title: "Achievements", modal: false)
  app = session.run_async.app
  cache_dir = File.join(dir, "achievements")
  window = Gemba::AchievementsWindow.new(app, handle, session, library, config, nil, cache_dir)
  Built.new(app, window, config, cache_dir)
end

private def with_window(title : String, &)
  dir = File.tempname("achievements_window_spec")
  Dir.mkdir(dir)
  built = build(dir, title)
  begin
    yield built
  ensure
    built.app.destroy
    FileUtils.rm_rf(dir)
  end
end

private def sample : Array(Achievement)
  [
    Achievement.new(1_u32, "Zed", "", 10, "0xH0000=1", Achievement::CORE),
    Achievement.new(2_u32, "Apple", "", 5, "0xH0000=1", Achievement::CORE, Time.utc(2026, 1, 2, 12, 0)),
    Achievement.new(3_u32, "Mango", "", 25, "0xH0000=1", Achievement::CORE, Time.utc(2026, 1, 5, 9, 30)),
  ]
end

private def shown(time : Time) : String
  time.to_local.to_s("%Y-%m-%d %H:%M")
end

private def click_heading(built : Built, column : String) : Nil
  built.app.tcl_eval("eval [#{built.window.table.path} heading #{column} -command]")
end

private def names(built : Built) : Array(String)
  built.window.rows.map(&.[0])
end

private def sync_disabled?(built : Built) : Bool
  built.app.command(built.window.sync_button.path, :instate, "disabled") == "1"
end

describe Gemba::AchievementsWindow do
  it "lists the loaded game's achievements: earned first, newest on top, then the rest by title" do
    with_window("achievements_window_spec_1") do |built|
      built.window.update(ALPHA, sample)

      names(built).should eq ["Mango", "Apple", "Zed"]
      built.window.rows[0].should eq({"Mango", "25", shown(Time.utc(2026, 1, 5, 9, 30))})
      built.window.rows[2].should eq({"Zed", "10", ""})
      built.window.status_text.should eq "2 / 3 earned"
      built.window.selected_game.should_not(be_nil).rom_id.should eq ALPHA
      built.window.title.should eq "Achievements — Alpha Quest"
    end
  end

  it "shows the empty state for a library game other than the loaded one, and the list again on the way back" do
    with_window("achievements_window_spec_2") do |built|
      built.window.update(ALPHA, sample)

      built.window.select_game(BETA).should be_true
      built.window.rows.should be_empty
      built.window.status_text.should eq "No achievements loaded"

      built.window.select_game(ALPHA).should be_true
      built.window.rows.size.should eq 3

      built.window.select_game("AGB-NOPE-00000000").should be_false
    end
  end

  it "with no game loaded shows nothing selected and the empty state" do
    with_window("achievements_window_spec_3") do |built|
      built.window.update(nil, [] of Achievement)

      built.window.rows.should be_empty
      built.window.selected_game.should be_nil
      built.window.status_text.should eq "No achievements loaded"
      built.window.title.should eq "Achievements"
    end
  end

  it "a heading click sorts by that column, a second reverses it, and unearned rows stay last by date" do
    with_window("achievements_window_spec_4") do |built|
      built.window.update(ALPHA, sample)

      click_heading(built, "points")
      names(built).should eq ["Apple", "Zed", "Mango"]
      built.app.command(built.window.table.path, :heading, "points", "-text").should eq "Points ▲"
      click_heading(built, "points")
      names(built).should eq ["Mango", "Zed", "Apple"]

      click_heading(built, "name")
      names(built).should eq ["Apple", "Mango", "Zed"]

      # Earned: newest first by default, oldest first on the second
      # click, Zed (never earned) at the bottom both ways.
      click_heading(built, "earned")
      names(built).should eq ["Mango", "Apple", "Zed"]
      click_heading(built, "earned")
      names(built).should eq ["Apple", "Mango", "Zed"]

      # New data resets the sort.
      built.window.update(ALPHA, sample)
      names(built).should eq ["Mango", "Apple", "Zed"]
      built.app.command(built.window.table.path, :heading, "points", "-text").should eq "Points"
    end
  end

  it "Sync and Include Unofficial reach their callbacks with the widget's state" do
    with_window("achievements_window_spec_5") do |built|
      synced = 0
      seen = [] of Bool
      built.window.on_sync { synced += 1 }
      built.window.on_unofficial_changed { |value| seen << value }
      built.window.logged_in = true

      built.app.tcl_invoke(built.window.sync_button.path, "invoke")
      synced.should eq 1

      built.config.ra_unofficial?.should be_false
      built.app.tcl_invoke(built.window.unofficial_checkbox.path, "invoke")
      built.app.tcl_invoke(built.window.unofficial_checkbox.path, "invoke")
      seen.should eq [true, false]
    end
  end

  it "Sync is disabled until logged in and while a sync is in flight, and the status follows the outcome" do
    with_window("achievements_window_spec_6") do |built|
      built.window.update(ALPHA, sample)

      built.window.logged_in = false
      sync_disabled?(built).should be_true
      built.window.status_text.should eq "Not logged in"

      built.window.logged_in = true
      sync_disabled?(built).should be_false

      built.window.sync_started
      sync_disabled?(built).should be_true
      built.window.status_text.should eq "Syncing…"

      built.window.sync_finished(false)
      sync_disabled?(built).should be_false
      built.window.status_text.should eq "Sync failed"

      built.window.sync_finished(false, :no_game)
      built.window.status_text.should eq "No game loaded"

      built.window.sync_finished(true)
      built.window.status_text.should eq "2 / 3 earned"
    end
  end
end

describe Gemba::AchievementsWindow, "offline cache" do
  it "shows the cached list for a library game other than the loaded one" do
    with_window("achievements_window_spec_7") do |built|
      cached = [Achievement.new(9_u32, "Beta Only", "", 50, "0xH0000=1", Achievement::CORE, Time.utc(2026, 3, 1))]
      built.app.off_thread { Gemba::Achievements::Cache.write(BETA, cached, built.cache_dir) }
      built.window.update(ALPHA, sample)

      built.window.select_game(BETA).should be_true
      built.window.rows.should eq [{"Beta Only", "50", shown(Time.utc(2026, 3, 1))}]
      built.window.status_text.should eq "1 / 1 earned"

      built.window.select_game(ALPHA).should be_true
      names(built).should eq ["Mango", "Apple", "Zed"]
    end
  end

  it "prefers the loaded game's live list over a stale cache entry for the same rom_id" do
    with_window("achievements_window_spec_8") do |built|
      stale = [Achievement.new(1_u32, "Zed", "", 10, "0xH0000=1", Achievement::CORE)]
      built.app.off_thread { Gemba::Achievements::Cache.write(ALPHA, stale, built.cache_dir) }

      built.window.update(ALPHA, sample)
      names(built).should eq ["Mango", "Apple", "Zed"]
      built.window.status_text.should eq "2 / 3 earned"
    end
  end

  it "falls back to the loaded game's own cache while its live list is empty" do
    with_window("achievements_window_spec_9") do |built|
      built.app.off_thread { Gemba::Achievements::Cache.write(ALPHA, sample, built.cache_dir) }

      built.window.update(ALPHA, [] of Achievement)
      names(built).should eq ["Mango", "Apple", "Zed"]

      # Nothing cached for Beta, and nothing live either.
      built.window.select_game(BETA).should be_true
      built.window.rows.should be_empty
      built.window.status_text.should eq "No achievements loaded"
    end
  end
end
