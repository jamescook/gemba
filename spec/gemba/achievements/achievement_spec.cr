require "../../spec_helper"

private def parse(json : String, include_unofficial : Bool = false) : Array(Gemba::Achievements::Achievement)
  Gemba::Achievements::Achievement.from_patch(JSON.parse(json), include_unofficial: include_unofficial)
end

describe Gemba::Achievements::Achievement do
  describe ".from_patch" do
    it "parses the fields the site sends" do
      list = parse(<<-JSON)
        [{"ID":101,"Title":"First Steps","Description":"Leave the house","Points":5,"MemAddr":"0xH0000=1","Flags":3}]
        JSON

      list.size.should eq 1
      first = list[0]
      first.id.should eq 101_u32
      first.title.should eq "First Steps"
      first.description.should eq "Leave the house"
      first.points.should eq 5
      first.memaddr.should eq "0xH0000=1"
      first.flags.should eq Gemba::Achievements::Achievement::CORE
      first.earned?.should be_false
    end

    it "skips an entry with an empty MemAddr - nothing to evaluate" do
      list = parse(<<-JSON)
        [
          {"ID":1,"Title":"a","Points":1,"MemAddr":"","Flags":3},
          {"ID":2,"Title":"b","Points":1,"Flags":3},
          {"ID":3,"Title":"c","Points":1,"MemAddr":"0xH0000=1","Flags":3}
        ]
        JSON

      list.map(&.id).should eq [3_u32]
    end

    it "keeps only core (Flags 3) by default, and unofficial (Flags 5) when asked" do
      json = <<-JSON
        [
          {"ID":1,"Title":"core","Points":1,"MemAddr":"0xH0000=1","Flags":3},
          {"ID":2,"Title":"unofficial","Points":1,"MemAddr":"0xH0000=1","Flags":5},
          {"ID":3,"Title":"local","Points":1,"MemAddr":"0xH0000=1","Flags":1}
        ]
        JSON

      parse(json).map(&.id).should eq [1_u32]
      parse(json, include_unofficial: true).map(&.id).should eq [1_u32, 2_u32]
    end

    it "skips the ids RA reserves for injected system messages" do
      list = parse(<<-JSON)
        [
          {"ID":100000001,"Title":"system message","Points":0,"MemAddr":"0xH0000=1","Flags":3},
          {"ID":100000000,"Title":"last real id","Points":0,"MemAddr":"0xH0000=1","Flags":3}
        ]
        JSON

      list.map(&.id).should eq [100_000_000_u32]
    end

    it "accepts numbers sent as strings and drops an entry with no usable id" do
      list = parse(<<-JSON)
        [
          {"ID":"7","Title":"stringy","Points":"10","MemAddr":"0xH0000=1","Flags":"3"},
          {"ID":"seven","Title":"broken","Points":1,"MemAddr":"0xH0000=1","Flags":3}
        ]
        JSON

      list.map(&.id).should eq [7_u32]
      list[0].points.should eq 10
    end

    it "is empty for a missing or non-array Achievements value" do
      Gemba::Achievements::Achievement.from_patch(nil, include_unofficial: true).should be_empty
      parse(%("nope"), include_unofficial: true).should be_empty
    end
  end

  it "#earn returns a copy marked earned, leaving the original alone" do
    achievement = Gemba::Achievements::Achievement.new(id: 1_u32, title: "t", description: "", points: 1,
      memaddr: "0xH0000=1", flags: 3)
    at = Time.utc(2026, 8, 30, 12, 0, 0)

    earned = achievement.earn(at)
    earned.earned?.should be_true
    earned.earned_at.should eq at
    earned.id.should eq 1_u32
    achievement.earned?.should be_false
  end
end
