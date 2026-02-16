# frozen_string_literal: true

require 'bundler/setup'
require 'rbconfig'
require 'rake/testtask'

# -- Compile -----------------------------------------------------------------

ext_dir = File.expand_path('ext/teek_mgba', __dir__)
lib_dir = File.expand_path('lib', __dir__)
so_name = "teek_mgba.#{RbConfig::CONFIG['DLEXT']}"

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
end

# -- Test --------------------------------------------------------------------

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.test_files = FileList['test/**/test_*.rb'] - FileList['test/test_helper.rb']
  t.ruby_opts << '-r test_helper'
  t.verbose = true
end

task test: :compile

# -- Dependencies (macOS / platforms without libmgba-dev) --------------------

desc "Download and build libmgba from source"
task :deps do
  require 'fileutils'
  require 'etc'

  vendor_dir  = File.expand_path('vendor')
  mgba_src    = File.join(vendor_dir, 'mgba')
  build_dir   = File.join(vendor_dir, 'build')
  install_dir = File.join(vendor_dir, 'install')

  unless File.directory?(mgba_src)
    FileUtils.mkdir_p(vendor_dir)
    sh "git clone --depth 1 --branch 0.10.3 https://github.com/mgba-emu/mgba.git #{mgba_src}"
  end

  FileUtils.mkdir_p(build_dir)
  cmake_flags = %W[
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
    -DCMAKE_INSTALL_PREFIX=#{install_dir}
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  ].join(' ')

  sh "cmake -S #{mgba_src} -B #{build_dir} #{cmake_flags}"
  sh "cmake --build #{build_dir} -j #{Etc.nprocessors}"
  sh "cmake --install #{build_dir}"

  puts "libmgba built and installed to #{install_dir}"
end

# -- Docker ------------------------------------------------------------------

namespace :docker do
  DOCKERFILE = 'Dockerfile.ci-test'
  DOCKER_LABEL = 'project=teek-mgba'
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
    base = tcl_version == '8.6' ? 'teek-mgba-ci-8' : 'teek-mgba-ci-9'
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
    cmd = "docker run --rm --init"
    cmd += " -v #{Dir.pwd}/coverage:/app/coverage"
    cmd += " -e TCL_VERSION=#{tcl_version}"
    cmd += " -e TEST='#{ENV['TEST']}'" if ENV['TEST']
    cmd += " -e TESTOPTS='#{ENV['TESTOPTS']}'" if ENV['TESTOPTS']
    if ENV['COVERAGE'] == '1'
      cmd += " -e COVERAGE=1"
      cmd += " -e COVERAGE_NAME=#{ENV['COVERAGE_NAME'] || 'mgba'}"
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
