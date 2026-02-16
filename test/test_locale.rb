# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../lib/gemba/locale"

class TestMGBALocale < Minitest::Test
  # -- Loading ---------------------------------------------------------------

  def test_load_english
    Gemba::Locale.load('en')
    assert_equal 'en', Gemba::Locale.language
  end

  def test_load_japanese
    Gemba::Locale.load('ja')
    assert_equal 'ja', Gemba::Locale.language
  end

  def test_fallback_to_english_for_unknown_locale
    Gemba::Locale.load('zz')
    # Should still load (fell back to en.yml) and return translations
    assert_equal 'File', Gemba::Locale.translate('menu.file')
  end

  def test_load_auto_detects_from_env
    original = ENV['LANG']
    ENV['LANG'] = 'ja_JP.UTF-8'
    Gemba::Locale.load
    assert_equal 'ja', Gemba::Locale.language
  ensure
    ENV['LANG'] = original
    Gemba::Locale.load('en')
  end

  def test_load_auto_string_treated_as_auto_detect
    original = ENV['LANG']
    ENV['LANG'] = 'en_US.UTF-8'
    Gemba::Locale.load('auto')
    assert_equal 'en', Gemba::Locale.language
  ensure
    ENV['LANG'] = original
    Gemba::Locale.load('en')
  end

  # -- Translation -----------------------------------------------------------

  def test_translate_english_string
    Gemba::Locale.load('en')
    assert_equal 'File', Gemba::Locale.translate('menu.file')
  end

  def test_translate_japanese_string
    Gemba::Locale.load('ja')
    assert_equal 'ファイル', Gemba::Locale.translate('menu.file')
  end

  def test_translate_nested_key
    Gemba::Locale.load('en')
    assert_equal 'Video', Gemba::Locale.translate('settings.video')
    assert_equal 'ROM Info', Gemba::Locale.translate('rom_info.title')
  end

  def test_translate_with_interpolation
    Gemba::Locale.load('en')
    result = Gemba::Locale.translate('toast.state_saved', slot: 3)
    assert_equal 'State saved to slot 3', result
  end

  def test_translate_with_multiple_vars
    Gemba::Locale.load('en')
    # dialog.game_running_msg has {name}
    result = Gemba::Locale.translate('dialog.game_running_msg', name: 'Zelda')
    assert_equal 'Another game is running. Switch to Zelda?', result
  end

  def test_translate_japanese_with_interpolation
    Gemba::Locale.load('ja')
    result = Gemba::Locale.translate('toast.state_saved', slot: 5)
    assert_includes result, '5'
  end

  def test_translate_missing_key_returns_key
    Gemba::Locale.load('en')
    assert_equal 'nonexistent.key', Gemba::Locale.translate('nonexistent.key')
  end

  def test_translate_partial_key_returns_key
    Gemba::Locale.load('en')
    # 'menu' exists but is a Hash, not a string
    assert_equal 'menu', Gemba::Locale.translate('menu')
  end

  # -- Alias -----------------------------------------------------------------

  def test_t_alias
    Gemba::Locale.load('en')
    assert_equal 'File', Gemba::Locale.t('menu.file')
    assert_equal Gemba::Locale.translate('menu.file'),
                 Gemba::Locale.t('menu.file')
  end

  # -- Available languages ---------------------------------------------------

  def test_available_languages
    langs = Gemba::Locale.available_languages
    assert_includes langs, 'en'
    assert_includes langs, 'ja'
    assert_equal langs, langs.sort, 'should be sorted'
  end

  # -- Translatable mixin ----------------------------------------------------

  def test_translatable_mixin
    klass = Class.new { include Gemba::Locale::Translatable; public :translate, :t }
    obj = klass.new
    Gemba::Locale.load('en')
    assert_equal 'File', obj.translate('menu.file')
    assert_equal 'File', obj.t('menu.file')
  end

  def test_translatable_mixin_with_interpolation
    klass = Class.new { include Gemba::Locale::Translatable; public :translate }
    obj = klass.new
    Gemba::Locale.load('en')
    assert_equal 'State saved to slot 7', obj.translate('toast.state_saved', slot: 7)
  end

  # -- Completeness ----------------------------------------------------------

  def test_en_and_ja_have_same_keys
    en_path = File.expand_path('../lib/gemba/locales/en.yml', __dir__)
    ja_path = File.expand_path('../lib/gemba/locales/ja.yml', __dir__)
    en = YAML.safe_load_file(en_path)
    ja = YAML.safe_load_file(ja_path)

    en_keys = flatten_keys(en)
    ja_keys = flatten_keys(ja)

    missing_in_ja = en_keys - ja_keys
    missing_in_en = ja_keys - en_keys

    assert_empty missing_in_ja, "Keys in en.yml missing from ja.yml: #{missing_in_ja.join(', ')}"
    assert_empty missing_in_en, "Keys in ja.yml missing from en.yml: #{missing_in_en.join(', ')}"
  end

  private

  def flatten_keys(hash, prefix = nil)
    hash.flat_map do |key, value|
      full_key = prefix ? "#{prefix}.#{key}" : key.to_s
      if value.is_a?(Hash)
        flatten_keys(value, full_key)
      else
        [full_key]
      end
    end
  end
end
