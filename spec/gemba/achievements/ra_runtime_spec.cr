require "../../spec_helper"

describe Gemba::Achievements::RARuntime do
  it "#do_frame returns the triggered achievement id once its condition becomes true" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.activate(7_u32, "0xH0000=1")

    mem = 0_u32
    runtime.do_frame { |_addr, _nbytes| mem }.should be_empty

    mem = 1_u32
    runtime.do_frame { |_addr, _nbytes| mem }.should eq [7_u32]
  end

  it "#activate raises ArgumentError for a memaddr rcheevos rejects" do
    runtime = Gemba::Achievements::RARuntime.new
    expect_raises(ArgumentError) { runtime.activate(1_u32, "not a valid condition (((") }
  end

  it "#count tracks activate/deactivate" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.count.should eq 0

    runtime.activate(1_u32, "0xH0000=1")
    runtime.activate(2_u32, "0xH0001=1")
    runtime.count.should eq 2

    runtime.deactivate(1_u32)
    runtime.count.should eq 1
  end

  it "#clear resets the runtime and drops the activated count" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.activate(1_u32, "0xH0000=1")

    runtime.clear
    runtime.count.should eq 0
    runtime.do_frame { |_addr, _nbytes| 1_u32 }.should be_empty
  end

  it "#activate_richpresence and #get_richpresence reflect the last #do_frame's memory" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.activate_richpresence("Display:\nScore: @Number(0xH0000)").should be_true

    runtime.do_frame { |_addr, _nbytes| 42_u32 }
    runtime.get_richpresence { |_addr, _nbytes| 42_u32 }.should eq "Score: 42"
  end

  it "#activate_richpresence returns false for an unparsable script" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.activate_richpresence("not a valid rich presence script (((").should be_false
  end

  it "#get_richpresence returns nil when no script is loaded" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.get_richpresence { |_addr, _nbytes| 0_u32 }.should be_nil
  end
end

describe "RetroAchievements address translation" do
  it "maps the low 32KB onto IWRAM" do
    Gemba::Achievements::RARuntime.to_gba_address(0_u32).should eq 0x03000000_u32
    Gemba::Achievements::RARuntime.to_gba_address(0x7FFF_u32).should eq 0x03007FFF_u32
  end

  it "maps everything from 0x8000 up onto EWRAM, rebased" do
    Gemba::Achievements::RARuntime.to_gba_address(0x8000_u32).should eq 0x02000000_u32
    Gemba::Achievements::RARuntime.to_gba_address(0x8100_u32).should eq 0x02000100_u32
  end

  it "#richpresence_active? tracks activation and is cleared by #clear" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.richpresence_active?.should be_false

    runtime.activate_richpresence("Display:\nHi").should be_true
    runtime.richpresence_active?.should be_true

    runtime.clear
    runtime.richpresence_active?.should be_false
  end

  it "#richpresence_active? stays false when the script fails to parse" do
    runtime = Gemba::Achievements::RARuntime.new
    runtime.activate_richpresence("not a valid script (((").should be_false
    runtime.richpresence_active?.should be_false
  end
end
