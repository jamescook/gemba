require "./spec_helper"

# Smoke test only; real coverage lives in each piece's own spec file.
describe Gemba do
  it "loads" do
    Gemba::VERSION.should eq "0.1.0"
  end
end
