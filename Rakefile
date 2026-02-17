# frozen_string_literal: true

require 'bundler/setup'
require 'rbconfig'
require 'rake/testtask'

# -- Compile -----------------------------------------------------------------

ext_dir = File.expand_path('ext/gemba', __dir__)
lib_dir = File.expand_path('lib', __dir__)
so_name = "gemba_ext.#{RbConfig::CONFIG['DLEXT']}"

desc "Compile C extension"
task :compile do
  Dir.chdir(ext_dir) do
    sh RbConfig.ruby, 'extconf.rb' unless File.exist?('Makefile')
    sh 'make'
  end
  cp File.join(ext_dir, so_name), lib_dir
end

desc "Remove build artifacts"
task :clobber do
  Dir.chdir(ext_dir) do
    sh 'make clean' if File.exist?('Makefile')
  end
  rm_f Dir.glob("#{ext_dir}/{Makefile,*.o,*.so,*.bundle,*.def,mkmf.log}")
  rm_f File.join(lib_dir, so_name)
  rm_rf File.expand_path('vendor/build', __dir__)
end

# -- Test --------------------------------------------------------------------

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.test_files = FileList['test/**/test_*.rb'] - FileList['test/test_helper.rb']
  t.ruby_opts << '-r test_helper'
  t.verbose = true
end

task test: :compile

# Isolate tests from the user's real config/saves/recordings.
task 'test:isolate_config' do
  require 'tmpdir'
  ENV['GEMBA_CONFIG_DIR'] ||= Dir.mktmpdir('gemba-test')
end
Rake::Task['test'].enhance(['test:isolate_config'])

# -- Dependencies (macOS / platforms without libmgba-dev) --------------------

desc "Download and build libmgba from source"
task :deps do
  if RUBY_PLATFORM =~ /mingw|mswin/
    abort "rake deps is not needed on Windows — install via MSYS2:\n" \
          "  pacman -S mingw-w64-ucrt-x86_64-mgba"
  end

  # cmake needs C and C++ compilers; check everything up front.
  needed = %w[cmake git make]
  needed += RUBY_PLATFORM =~ /mingw|mswin/ ? %w[gcc g++] : %w[cc c++]
  missing = needed.reject { |cmd| ENV['PATH'].split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) || File.executable?(File.join(d, "#{cmd}.exe")) } }
  unless missing.empty?
    find_bin = ->(name) { ENV['PATH'].split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, name)) } }
    hint = if RUBY_PLATFORM =~ /darwin/
             "  xcode-select --install && brew install cmake"
           elsif find_bin['dnf']
             "  sudo dnf install cmake gcc gcc-c++ make git"
           elsif find_bin['apt']
             "  sudo apt install cmake build-essential git"
           elsif find_bin['pacman']
             "  sudo pacman -S cmake gcc make git"
           elsif find_bin['apk']
             "  apk add cmake gcc g++ make git"
           else
             "  Install: #{missing.join(', ')}"
           end
    abort "Missing required tools: #{missing.join(', ')}\n#{hint}"
  end

  require 'fileutils'
  require 'etc'

  # Install to a system-visible prefix so `gem install gemba` finds libmgba
  # without needing MGBA_DIR. Mirrors what `brew install` would do.
  default_prefix = RUBY_PLATFORM =~ /darwin/ ? '/opt/homebrew' : '/usr/local'
  install_dir = ENV.fetch('MGBA_PREFIX', default_prefix)

  vendor_dir  = File.expand_path('vendor')
  mgba_src    = File.join(vendor_dir, 'mgba')
  build_dir   = File.join(vendor_dir, 'build')

  unless File.directory?(mgba_src)
    FileUtils.mkdir_p(vendor_dir)
    sh "git clone --depth 1 --branch 0.10.5 https://github.com/mgba-emu/mgba.git #{mgba_src}"
  end

  FileUtils.mkdir_p(build_dir)
  # -DMARKDOWN= disables mgba's README-to-HTML build; it finds kramdown
  # on PATH from Ruby gems, but Bundler blocks it. We only need the static lib.
  cmake_flags = %W[
    -DMARKDOWN=
    -DBUILD_SHARED=OFF
    -DBUILD_STATIC=ON
    -DBUILD_QT=OFF
    -DBUILD_SDL=OFF
    -DBUILD_GL=OFF
    -DBUILD_GLES2=OFF
    -DBUILD_GLES3=OFF
    -DBUILD_LIBRETRO=OFF
    -DSKIP_FRONTEND=ON
    -DUSE_SQLITE3=OFF
    -DUSE_ELF=OFF
    -DUSE_LZMA=OFF
    -DUSE_EDITLINE=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_INSTALL_PREFIX=#{install_dir}
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  ].join(' ')

  sh "cmake -S #{mgba_src} -B #{build_dir} #{cmake_flags}"
  sh "cmake --build #{build_dir} -j #{Etc.nprocessors}"
  install_cmd = "cmake --install #{build_dir}"
  # System prefixes like /usr/local need root on Linux; Homebrew doesn't.
  if !File.writable?(install_dir) && !RUBY_PLATFORM.match?(/mingw|mswin/)
    install_cmd = "sudo #{install_cmd}"
  end
  sh install_cmd

  puts "libmgba built and installed to #{install_dir}"
  puts "  headers: #{install_dir}/include/mgba/"
  puts "  libs:    #{install_dir}/lib/"
end

# -- Documentation -----------------------------------------------------------

namespace :docs do
  desc "Install docs dependencies (docs_site/Gemfile)"
  task :setup do
    Dir.chdir('docs_site') do
      Bundler.with_unbundled_env { sh 'bundle install' }
    end
  end

  task :yard_clean do
    FileUtils.rm_rf('doc')
    FileUtils.rm_rf('docs_site/_api')
    FileUtils.rm_rf('docs_site/_site')
    FileUtils.rm_rf('docs_site/.jekyll-cache')
    FileUtils.rm_f('docs_site/assets/js/search-data.json')
    FileUtils.rm_f('docs_site/internals.md')
  end

  # Copy INTERNALS.md from repo root into docs_site/ with Jekyll front matter.
  # Source of truth stays at the repo root (visible on GitHub).
  task :copy_internals do
    content = File.read('INTERNALS.md')
    front_matter = "---\nlayout: default\ntitle: Internals\nnav_order: 80\n---\n\n"
    File.write('docs_site/internals.md', front_matter + content)
  end

  desc "Generate YARD JSON (uses docs_site/Gemfile)"
  task yard_json: :yard_clean do
    Bundler.with_unbundled_env do
      sh 'BUNDLE_GEMFILE=docs_site/Gemfile bundle exec yard doc'
    end
  end

  desc "Generate per-method coverage JSON from SimpleCov data"
  task :method_coverage do
    if Dir.exist?('coverage/results')
      require_relative 'lib/gemba/method_coverage_service'
      Gemba::MethodCoverageService.new(coverage_dir: 'coverage').call
    else
      puts "No coverage data found (run tests with COVERAGE=1 first)"
    end
  end

  desc "Generate API docs (YARD JSON -> HTML)"
  task yard: [:yard_json, :method_coverage] do
    Bundler.with_unbundled_env do
      sh 'BUNDLE_GEMFILE=docs_site/Gemfile bundle exec ruby docs_site/build_api_docs.rb'
    end
  end

  # Pulled from teek — no recordings yet, but keeping in case we add demos later.
  desc "Bless recordings from recordings/ into docs_site/assets/recordings/"
  task :bless_recordings do
    require 'fileutils'
    src = 'recordings'
    dest = 'docs_site/assets/recordings'
    FileUtils.mkdir_p(dest)
    videos = Dir.glob("#{src}/*.{mp4,webm}")
    if videos.empty?
      puts "No recordings in #{src}/ to bless."
      next
    end
    videos.each do |path|
      FileUtils.cp(path, dest)
      puts "  #{File.basename(path)} -> #{dest}/"
    end
    puts "Blessed #{videos.size} recording(s)."
  end

  desc "Generate recordings gallery page"
  task :recordings do
    sh 'ruby docs_site/build_recordings.rb'
  end

  desc "Generate full docs site (YARD + Jekyll)"
  task generate: [:yard, :copy_internals] do
    Dir.chdir('docs_site') do
      Bundler.with_unbundled_env { sh 'bundle exec jekyll build' }
    end
    puts "Docs generated in docs_site/_site/"
  end

  desc "Serve docs locally (watches lib/ and ext/ for changes, regenerates API docs)"
  task serve: [:yard, :copy_internals] do
    require 'listen'

    # Use absolute paths so Dir.chdir('docs_site') for Jekyll doesn't confuse Listen.
    root = __dir__
    gemfile = File.join(root, 'docs_site', 'Gemfile')

    rebuild_docs = proc do |modified, added, _removed|
      changed = (modified + added).select { |f| f.end_with?('.rb', '.c', '.h', '.erb', '.md') }
      next if changed.empty?
      puts "\n--- Changed: #{changed.map { |f| f.sub("#{root}/", '') }.join(', ')}"
      puts "--- Regenerating API docs..."
      Bundler.with_unbundled_env do
        system("BUNDLE_GEMFILE=#{gemfile} bundle exec yard doc --quiet", chdir: root) &&
          system("BUNDLE_GEMFILE=#{gemfile} bundle exec ruby docs_site/build_api_docs.rb", chdir: root)
      end
      # Re-copy INTERNALS.md in case it changed
      Rake::Task['docs:copy_internals'].execute
      puts "--- Done. Jekyll will pick up changes automatically."
    end

    listener = Listen.to(
      File.join(root, 'lib'),
      File.join(root, 'ext'),
      File.join(root, 'docs_site', 'templates'),
      only: /\.(rb|c|h|erb)$/,
      &rebuild_docs
    )
    root_listener = Listen.to(root, only: /\.md$/) do |mod, add, _rem|
      # Only care about top-level markdown files (INTERNALS.md, README.md, etc.)
      changed = (mod + add).select { |f| File.dirname(f) == root }
      rebuild_docs.call(changed, [], []) unless changed.empty?
    end
    listener.start
    root_listener.start
    puts "Watching lib/, ext/, docs_site/templates/, *.md for changes"

    Dir.chdir(File.join(root, 'docs_site')) do
      Bundler.with_unbundled_env { sh 'bundle exec jekyll serve --watch --livereload' }
    end
  end
end

# Aliases for convenience
task doc: 'docs:yard'
task yard: 'docs:yard'

# -- Docker ------------------------------------------------------------------

# -- Build -------------------------------------------------------------------

desc "Build gem (aborts if working tree is dirty)"
task :build do
  unless `git status --porcelain`.strip.empty?
    abort "Working tree is dirty. Commit or stash changes before building the gem."
  end
  sh "gem build gemba.gemspec"
end

desc "Remove libmgba files installed by `rake deps`"
task 'deps:uninstall' do
  manifest = File.expand_path('vendor/build/install_manifest.txt', __dir__)
  unless File.exist?(manifest)
    abort "No install manifest found at #{manifest} — nothing to uninstall."
  end
  files = File.readlines(manifest, chomp: true)
  files.each do |f|
    if File.exist?(f)
      rm f
      puts "  removed #{f}"
    end
  end
  # Clean up empty directories left behind
  dirs = files.map { |f| File.dirname(f) }.uniq.sort_by { |d| -d.length }
  dirs.each { |d| Dir.rmdir(d) if File.directory?(d) && Dir.empty?(d) rescue nil }
  puts "Uninstalled #{files.size} file(s) from manifest."
end

desc "Smoke test: build, install, require, load ROM, run 1 frame"
task 'release:smoke' => :build do
  require_relative 'lib/gemba/version'
  version = Gemba::VERSION
  gem_file = "gemba-#{version}.gem"
  test_rom = File.expand_path('test/fixtures/test.gba', __dir__)

  abort "Test ROM not found: #{test_rom}" unless File.exist?(test_rom)
  abort "Gem not found: #{gem_file}" unless File.exist?(gem_file)

  # Clean slate: remove everything and start fresh
  sh "gem uninstall gemba --all --executables --force 2>/dev/null || true"
  manifest = File.expand_path('vendor/build/install_manifest.txt', __dir__)
  Rake::Task['deps:uninstall'].invoke if File.exist?(manifest)
  Rake::Task['clobber'].invoke

  # Fresh install from scratch
  Rake::Task['deps'].invoke
  sh "gem install #{gem_file} --no-document"
  # Run from a temp dir with a clean env so Ruby loads the installed gem,
  # not the local lib/ (Bundler's load path would shadow the gem otherwise).
  require 'tmpdir'
  smoke_script = File.expand_path('scripts/smoke_test.rb', __dir__)
  Dir.mktmpdir('gemba-smoke') do |tmpdir|
    Bundler.with_unbundled_env do
      sh RbConfig.ruby, smoke_script, version, test_rom, chdir: tmpdir
    end
  end
end

# -- Docker ------------------------------------------------------------------

namespace :docker do
  DOCKERFILE = 'Dockerfile.ci-test'
  DOCKER_LABEL = 'project=gemba'
  BUILD_DEPS_DIR = '_build_deps'

  # Copy local teek/teek-sdl2 source into _build_deps/ for Docker builds.
  # Opt-in via LOCAL_DEPS=1 (auto-detect sibling repos) or explicit
  # TEEK_PATH / TEEK_SDL2_PATH env vars.
  #
  # Returns extra --build-arg flags for docker build.
  def prepare_build_deps
    require 'fileutils'
    FileUtils.rm_rf(BUILD_DEPS_DIR)
    FileUtils.mkdir_p(BUILD_DEPS_DIR)

    build_args = []
    use_local = ENV['LOCAL_DEPS'] || ENV['TEEK_PATH'] || ENV['TEEK_SDL2_PATH']
    return build_args unless use_local

    teek_path = ENV['TEEK_PATH'] || File.expand_path('../teek', Dir.pwd)
    teek_sdl2_path = ENV['TEEK_SDL2_PATH'] || File.join(teek_path, 'teek-sdl2')

    if File.exist?(File.join(teek_path, 'teek.gemspec'))
      puts "  Using local teek: #{teek_path}"
      sync_dep(teek_path, File.join(BUILD_DEPS_DIR, 'teek'))
      build_args += ['--build-arg', 'TEEK_PATH=/deps/teek']
    end

    if File.exist?(File.join(teek_sdl2_path, 'teek-sdl2.gemspec'))
      puts "  Using local teek-sdl2: #{teek_sdl2_path}"
      sync_dep(teek_sdl2_path, File.join(BUILD_DEPS_DIR, 'teek-sdl2'))
      build_args += ['--build-arg', 'TEEK_SDL2_PATH=/deps/teek-sdl2']
    end

    build_args
  end

  # Copy only what bundler needs to compile a gem: lib/, ext/, gemspec.
  def sync_dep(src, dest)
    require 'fileutils'
    FileUtils.mkdir_p(dest)
    %w[lib ext].each do |subdir|
      src_sub = File.join(src, subdir)
      FileUtils.cp_r(src_sub, dest) if File.directory?(src_sub)
    end
    Dir.glob(File.join(src, '*.gemspec')).each { |f| FileUtils.cp(f, dest) }
  end

  def cleanup_build_deps
    FileUtils.rm_rf(BUILD_DEPS_DIR)
  end

  def docker_image_name(tcl_version, ruby_version = nil)
    ruby_version ||= ruby_version_from_env
    base = tcl_version == '8.6' ? 'gemba-ci-8' : 'gemba-ci-9'
    ruby_version == '4.0' ? base : "#{base}-ruby#{ruby_version}"
  end

  def warn_if_containers_running(image_name)
    running = `docker ps --filter ancestor=#{image_name} --format '{{.ID}} {{.Status}}'`.strip
    return if running.empty?
    count = running.lines.size
    warn "\n  #{count} container(s) already running on #{image_name}:"
    running.lines.each { |l| warn "   #{l.strip}" }
    warn "   Consider: docker kill $(docker ps -q --filter ancestor=#{image_name})\n"
  end

  def tcl_version_from_env
    version = ENV.fetch('TCL_VERSION', '9.0')
    unless ['8.6', '9.0'].include?(version)
      abort "Invalid TCL_VERSION='#{version}'. Must be '8.6' or '9.0'."
    end
    version
  end

  def ruby_version_from_env
    ENV.fetch('RUBY_VERSION', '4.0')
  end

  desc "Build Docker image (TCL_VERSION=9.0|8.6, RUBY_VERSION=4.0|..., LOCAL_DEPS=1)"
  task :build do
    tcl_version = tcl_version_from_env
    ruby_version = ruby_version_from_env
    image_name = docker_image_name(tcl_version, ruby_version)

    dep_args = prepare_build_deps

    verbose = ENV['VERBOSE'] || ENV['V']
    quiet = !verbose
    if quiet
      puts "Building Docker image for Ruby #{ruby_version}, Tcl #{tcl_version}... (VERBOSE=1 for details)"
    else
      puts "Building Docker image for Ruby #{ruby_version}, Tcl #{tcl_version}..."
    end
    cmd = "docker build -f #{DOCKERFILE}"
    cmd += " -q" if quiet
    cmd += " --label #{DOCKER_LABEL}"
    cmd += " --build-arg RUBY_VERSION=#{ruby_version}"
    cmd += " --build-arg TCL_VERSION=#{tcl_version}"
    dep_args.each_slice(2) { |flag, val| cmd += " #{flag} #{val}" }
    cmd += " -t #{image_name} ."

    begin
      sh cmd, verbose: !quiet
    ensure
      cleanup_build_deps
    end
  end

  desc "Run tests in Docker (TCL_VERSION=9.0|8.6)"
  task test: :build do
    tcl_version = tcl_version_from_env
    ruby_version = ruby_version_from_env
    image_name = docker_image_name(tcl_version, ruby_version)

    require 'fileutils'
    FileUtils.mkdir_p('coverage')

    warn_if_containers_running(image_name)

    puts "Running tests in Docker (Ruby #{ruby_version}, Tcl #{tcl_version})..."
    screenshots_dir = File.join(Dir.pwd, 'test', 'screenshots')
    FileUtils.mkdir_p(screenshots_dir)

    cmd = "docker run --rm --init"
    cmd += " -v #{Dir.pwd}/coverage:/app/coverage"
    cmd += " -v #{screenshots_dir}:/app/test/screenshots"
    cmd += " -e TCL_VERSION=#{tcl_version}"
    cmd += " -e TEST='#{ENV['TEST']}'" if ENV['TEST']
    cmd += " -e TESTOPTS='#{ENV['TESTOPTS']}'" if ENV['TESTOPTS']
    cmd += " -e SEED='#{ENV['SEED']}'" if ENV['SEED']
    cmd += " -e CI='#{ENV['CI']}'" if ENV['CI']
    if ENV['COVERAGE'] == '1'
      cmd += " -e COVERAGE=1"
      cmd += " -e COVERAGE_NAME=#{ENV['COVERAGE_NAME'] || 'gemba'}"
    end
    cmd += " #{image_name}"
    cmd += " xvfb-run -a bundle exec rake test"

    sh cmd
  end

  desc "Run interactive shell in Docker"
  task shell: :build do
    tcl_version = tcl_version_from_env
    ruby_version = ruby_version_from_env
    image_name = docker_image_name(tcl_version, ruby_version)

    cmd = "docker run --rm --init -it"
    cmd += " -v #{Dir.pwd}/coverage:/app/coverage"
    cmd += " -e TCL_VERSION=#{tcl_version}"
    cmd += " #{image_name} bash"

    sh cmd
  end

  desc "Force rebuild Docker image (no cache)"
  task :rebuild do
    tcl_version = tcl_version_from_env
    ruby_version = ruby_version_from_env
    image_name = docker_image_name(tcl_version, ruby_version)

    dep_args = prepare_build_deps

    puts "Rebuilding Docker image (no cache)..."
    cmd = "docker build -f #{DOCKERFILE} --no-cache"
    cmd += " --label #{DOCKER_LABEL}"
    cmd += " --build-arg RUBY_VERSION=#{ruby_version}"
    cmd += " --build-arg TCL_VERSION=#{tcl_version}"
    dep_args.each_slice(2) { |flag, val| cmd += " #{flag} #{val}" }
    cmd += " -t #{image_name} ."

    begin
      sh cmd
    ensure
      cleanup_build_deps
    end
  end

  desc "Remove dangling Docker images"
  task :prune do
    sh "docker image prune -f --filter label=#{DOCKER_LABEL}"
  end

  Rake::Task['docker:test'].enhance { Rake::Task['docker:prune'].invoke }
end

task default: 'docker:test'
