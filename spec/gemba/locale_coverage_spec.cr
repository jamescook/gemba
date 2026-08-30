require "../spec_helper"

# Every translate("...") literal in src must resolve in every shipped
# locale. A key filed under the wrong YAML section doesn't error - it
# renders as the raw dotted key in the UI, which is exactly how
# "menu.open_replay_player" shipped broken once (filed under settings:
# instead of menu:). Literal keys only; dynamically-built keys (e.g.
# a "section." prefix + variable) are outside this net.
private KEY_PATTERN = /(?:Locale\.translate|Locale\.t|\btranslate|\bt)\(\s*"([a-z0-9_]+(?:\.[a-z0-9_]+)+)"/

private def translate_keys_in_src : Array(String)
  keys = [] of String
  Dir.glob(File.join(__DIR__, "..", "..", "src", "**", "*.cr")).each do |path|
    File.read(path).scan(KEY_PATTERN) do |match|
      keys << match[1]
    end
  end
  keys.uniq!.sort!
end

describe Gemba::Locale do
  it "resolves every translate key used in src, in every shipped locale" do
    keys = translate_keys_in_src
    keys.should_not be_empty # the scan itself must be finding things

    begin
      Gemba::Locale.available_languages.each do |lang|
        Gemba::Locale.load(lang)
        missing = keys.reject { |key| Gemba::Locale.strings.has_key?(key) }
        missing.should(be_empty, "keys missing from #{lang}.yml: #{missing.join(", ")}")
      end
    ensure
      Gemba::Locale.load("en")
    end
  end
end
