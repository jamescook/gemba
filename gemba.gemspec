require_relative "lib/gemba/version"

Gem::Specification.new do |spec|
  spec.name          = "gemba"
  spec.version       = Gemba::VERSION
  spec.authors       = ["James Cook"]
  spec.email         = ["jcook.rubyist@gmail.com"]

  spec.summary       = "GBA emulator frontend powered by teek and libmgba"
  spec.description   = "Wraps libmgba's mCore C API and provides a full-featured GBA player with SDL2 rendering, input, save states, and a Tk-based settings UI"
  spec.homepage      = "https://github.com/jamescook/gemba"
  spec.licenses      = ["MIT"]

  spec.files         = Dir.glob("{lib,ext,test,assets,bin}/**/*").select { |f|
                         File.file?(f) && f !~ /\.(bundle|so|o|log)$/ &&
                           !f.include?('.dSYM/') && File.basename(f) != 'Makefile'
                       } + %w[gemba.gemspec THIRD_PARTY_NOTICES]
  spec.bindir        = "bin"
  spec.executables   = ["gemba"]
  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/gemba/extconf.rb"]
  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "teek", ">= 0.1.2"
  spec.add_dependency "teek-sdl2", ">= 0.2.1"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.0"
  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "method_source", "~> 1.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "listen", "~> 3.0"

  spec.requirements << "libmgba development headers"
  spec.add_development_dependency "webmock", "~> 3.0"
  spec.add_development_dependency "rubyzip", ">= 2.4"

  spec.requirements << "rubyzip gem >= 2.4 (optional, for loading ROMs from .zip files)"
end
