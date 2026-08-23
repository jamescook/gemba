require "yaml"

module Gemba
  # Lightweight YAML-backed localization - no external gem/shard, just
  # Crystal's stdlib YAML parser.
  #
  # Every key is dot-separated ("menu.file", "toast.state_saved") -
  # mostly 2 levels deep (section -> key -> string), but a few sections
  # go a level deeper, so #load flattens recursively rather than
  # assuming a fixed depth, into one Hash(String, String) for O(1)
  # lookup.
  module Locale
    class_getter language : String = "en"
    class_property strings : Hash(String, String) = {} of String => String

    # @param lang [String?] two-letter code ("en", "ja"), or nil/"auto"
    #   to detect from LANG/LC_ALL/LANGUAGE. Falls back to English (the
    #   whole file, not per-key) if the requested locale file doesn't
    #   exist.
    def self.load(lang : String? = nil) : String
      resolved = lang.nil? || lang == "auto" ? detect_language : lang
      path = locale_path(resolved)
      path = locale_path("en") unless File.exists?(path)

      flat = {} of String => String
      flatten(YAML.parse(File.read(path)), "", flat)

      @@strings = flat
      @@language = resolved
    end

    # Dot-separated key lookup with optional `{name}`-style interpolation
    # (plain String#gsub, not printf %{}).
    def self.translate(key : String, **vars) : String
      str = @@strings[key]?
      return key unless str

      vars.each { |k, v| str = str.gsub("{#{k}}", v.to_s) }
      str
    end

    def self.t(key : String, **vars) : String
      translate(key, **vars)
    end

    def self.available_languages : Array(String)
      Dir.glob(locale_path("*")).map { |file| File.basename(file, ".yml") }.sort!
    end

    private def self.flatten(node : YAML::Any, prefix : String, into : Hash(String, String)) : Nil
      case raw = node.raw
      when String
        into[prefix] = raw
      when Hash
        node.as_h.each do |key, value|
          child_key = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
          flatten(value, child_key, into)
        end
      end
    end

    private def self.detect_language : String
      env = ENV["LANG"]? || ENV["LC_ALL"]? || ENV["LANGUAGE"]? || "en"
      env[0, 2].downcase
    end

    private def self.locale_path(lang : String) : String
      File.join(__DIR__, "locales", "#{lang}.yml")
    end

    load("en") if @@strings.empty?

    # Mixin for classes that need translation access as instance methods.
    module Translatable
      private def translate(key : String, **vars) : String
        Locale.translate(key, **vars)
      end

      private def t(key : String, **vars) : String
        translate(key, **vars)
      end
    end
  end
end
