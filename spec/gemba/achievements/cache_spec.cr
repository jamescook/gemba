require "../../spec_helper"
require "file_utils"

private alias Achievement = Gemba::Achievements::Achievement
private alias Cache = Gemba::Achievements::Cache

private ROM_ID = "AGB-ALPH-11111111"

private def with_cache_dir(&)
  dir = File.tempname("achievements_cache_spec")
  begin
    yield File.join(dir, "achievements")
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def sample : Array(Achievement)
  [
    Achievement.new(1_u32, "Zed", "Do the thing", 10, "0xH0000=1", Achievement::CORE),
    Achievement.new(2_u32, "Apple", "", 5, "0xH0001=2", Achievement::UNOFFICIAL, Time.utc(2026, 1, 2, 12, 0, 30)),
  ]
end

describe Gemba::Achievements::Cache do
  it "round-trips a list through dir/<rom_id>.json, creating the directory, with synced_at alongside" do
    with_cache_dir do |dir|
      Cache.write(ROM_ID, sample, dir)

      file = File.join(dir, "#{ROM_ID}.json")
      File.exists?(file).should be_true
      data = JSON.parse(File.read(file))
      Time.parse_rfc3339(data["synced_at"].as_s).should be_close(Time.utc, 5.seconds)
      data["achievements"][1]["earned_at"].as_s.should eq "2026-01-02T12:00:30Z"
      data["achievements"][0]["earned_at"].raw.should be_nil

      Cache.read(ROM_ID, dir).should eq sample
    end
  end

  it "reads nil when no cache exists for the rom_id yet" do
    with_cache_dir do |dir|
      Cache.read(ROM_ID, dir).should be_nil
    end
  end

  it "reads nil, not an exception, from a file that isn't the expected JSON" do
    with_cache_dir do |dir|
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "#{ROM_ID}.json"), "{not json")

      Cache.read(ROM_ID, dir).should be_nil
    end
  end

  it "reads a file ruby gemba wrote - no memaddr/flags, string-typed numbers" do
    with_cache_dir do |dir|
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "#{ROM_ID}.json"), <<-JSON)
        {"synced_at":"2026-01-01T00:00:00Z","achievements":[
          {"id":"7","title":"Old","description":"From ruby","points":"15","earned_at":"2025-12-31T23:00:00Z"},
          {"id":8,"title":"Older","description":"","points":1,"earned_at":null}]}
        JSON

      list = Cache.read(ROM_ID, dir).should_not be_nil
      list.should eq [
        Achievement.new(7_u32, "Old", "From ruby", 15, "", 0, Time.utc(2025, 12, 31, 23, 0)),
        Achievement.new(8_u32, "Older", "", 1, "", 0),
      ]
    end
  end

  it "a later write replaces the earlier list" do
    with_cache_dir do |dir|
      Cache.write(ROM_ID, sample, dir)
      Cache.write(ROM_ID, [sample[0].earn(Time.utc(2026, 2, 1))], dir)

      Cache.read(ROM_ID, dir).should eq [sample[0].earn(Time.utc(2026, 2, 1))]
    end
  end
end
