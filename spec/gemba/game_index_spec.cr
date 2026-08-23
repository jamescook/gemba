require "../spec_helper"

describe Gemba::GameIndex do
  before_each { Gemba::GameIndex.reset! }
  after_each { Gemba::GameIndex.reset! }

  describe ".lookup" do
    it "returns nil for any code before #preload! has run" do
      Gemba::GameIndex.lookup("AGB-AXVE").should be_nil
    end

    it "returns the canonical name for a known GBA serial, once preloaded" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup("AGB-AXVE").should eq "Pokemon - Ruby Version (USA, Europe)"
    end

    it "returns the canonical name for a known GBC serial" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup("CGB-AAXD").should eq "Pokemon - Silberne Edition (Germany) (Beta) (SGB Enhanced) (GB Compatible)"
    end

    it "returns the canonical name for a known GB serial" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup("DMG-APAU").should eq "Pokemon - Red Version (USA, Europe) (SGB Enhanced)"
    end

    it "returns nil for an unknown serial" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup("AGB-ZZZZ").should be_nil
    end

    it "returns nil for an unrecognized platform prefix" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup("XYZ-ABCD").should be_nil
    end

    it "returns nil for nil or blank input" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup(nil).should be_nil
      Gemba::GameIndex.lookup("").should be_nil
    end
  end

  describe ".lookup_by_md5" do
    it "returns the canonical name for a known md5, case-insensitively" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup_by_md5("0007d212d9b76a466c7ca003d50c8c74", "gba")
        .should eq "MX 2002 Featuring Ricky Carmichael (USA, Europe)"
      Gemba::GameIndex.lookup_by_md5("0007D212D9B76A466C7CA003D50C8C74", "gba")
        .should eq "MX 2002 Featuring Ricky Carmichael (USA, Europe)"
    end

    it "returns nil for an unknown md5" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup_by_md5("0" * 32, "gba").should be_nil
    end

    it "returns nil for an unrecognized platform" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup_by_md5("0007d212d9b76a466c7ca003d50c8c74", "nes").should be_nil
    end

    it "returns nil for nil or blank md5" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup_by_md5(nil, "gba").should be_nil
      Gemba::GameIndex.lookup_by_md5("", "gba").should be_nil
    end
  end

  describe ".preload!" do
    it "is idempotent - a second call doesn't reload already-loaded data" do
      Gemba::GameIndex.preload!
      Gemba::GameIndex.preload!
      Gemba::GameIndex.lookup("AGB-AXVE").should eq "Pokemon - Ruby Version (USA, Europe)"
    end
  end
end
