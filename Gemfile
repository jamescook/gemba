# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# Auto-detect local teek/teek-sdl2 for development against unreleased changes.
# Checks TEEK_PATH / TEEK_SDL2_PATH env vars first, then falls back to
# sibling ../teek directory. No-op if neither exists (uses published gems).
#
# Skips auto-detection if a compiled extension was linked against a different
# Ruby version (e.g. libruby.4.0.dylib won't load under Ruby 3.4).

def ruby_version_compatible?(gem_path)
  current = RUBY_VERSION.split('.')[0..1].join('.')

  # Check compiled extensions for linked Ruby version (source of truth)
  Dir.glob(File.join(gem_path, 'lib', '*.{bundle,so}')).each do |ext|
    linked = `otool -L #{ext} 2>/dev/null` rescue nil
    linked ||= `ldd #{ext} 2>/dev/null` rescue nil
    next unless linked
    if linked =~ /libruby[.-](\d+\.\d+)/
      linked_version = $1
      if linked_version != current
        warn "teek-mgba Gemfile: skipping local #{gem_path} " \
             "(extension linked to Ruby #{linked_version}, running #{current})"
        return false
      end
    end
  end

  true
end

teek_path = ENV['TEEK_PATH'].to_s
teek_path = File.expand_path('../teek', __dir__) if teek_path.empty?

teek_sdl2_path = ENV['TEEK_SDL2_PATH'].to_s
teek_sdl2_path = File.join(teek_path, 'teek-sdl2') if teek_sdl2_path.empty?

if File.exist?(File.join(teek_path, 'teek.gemspec')) && ruby_version_compatible?(teek_path)
  gem 'teek', path: teek_path
end

if File.exist?(File.join(teek_sdl2_path, 'teek-sdl2.gemspec')) && ruby_version_compatible?(teek_sdl2_path)
  gem 'teek-sdl2', path: teek_sdl2_path
end
