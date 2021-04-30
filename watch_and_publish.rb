require 'filewatcher'
require 'socket'
require 'timeout'
require 'shellwords'
require 'rubygems'
require 'ostruct'

def usage
  [
    "Usage:",
    "  docker run --rm -p 9292:9293 -v /path/to/gems/basedir:/gems:ro IMAGE_ID <gem1/path> [gem2/path...]",
    "",
    "This container is meant to run locally, with a volume-mounted base",
    "directory and a list of gem directories to serve, specified as their",
    "relative paths from the base directory.  It will listen on port 9293."
  ].join("\n")
end

def nope(str)
  STDERR.puts
  STDERR.puts "ERROR"
  STDERR.puts
  STDERR.puts str
  exit(1)
end

# https://stackoverflow.com/a/9017896
def port_open?(port)
  seconds = 1
  Timeout::timeout(seconds) do
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
  end
rescue Timeout::Error
end

# print a command output as annotated
def annotated_command(*args, **kwargs)
  IO.popen(*args, **kwargs, err: [:child, :out]) do |io|
    name = yield(io) # this is a backwards way to do it, but I need a way to not mangle input args here
    io.each do |line|
      STDERR.puts "#{name}: #{line}"
    end
  end
end

# TODO: this writes the config file as a side effect of generating the command.
# That's because I wasted about 5 hours not knowing that specifying a config file
# to start the server (but not specifying one for the auth) means "invalid auth".
# So it works now and it's here now.
def gemstash_command(*args)
  config = Pathname.new(ENV["APPDIR"]) + "config.yml"
  unless config.exist?
    File.write(
      config,
      [
        "---",
        ":base_path: #{ENV["GEMSTASH_WORKDIR"]}",
        ":protected_fetch: false",
        # ":log_file: :stdout"    # note that this adds extra lines to the output of "gemstash authorize"
      ].join("\n")
    )
  end

  [
    ["bundle", "exec", "gemstash"],
    args,
    ["--config-file", config] # we need this EVERY TIME OR PUSHES WILL FAIL FOR NON-OBVIOUS REASONS
  ].flatten.shelljoin
end

def await_port_status(desired_state)
  loop do
    break if !!port_open?(ENV['SERVER_PORT']) == !!desired_state
    STDERR.puts("Waiting for Gemstash port_open? status to be #{desired_state}")
    sleep(1)
  end
end

# Run gemstash in a thread.  accept a block with whatever to do while we wait for the port to open
# return the thread, server IO.popen object, and the auth key to access the server
def run_gemstash
  await_port_status(false) # don't start until any old servers are dead

  STDERR.puts "Clearing gemstash dir"
  annotated_command("rm -rfv #{ENV["GEMSTASH_WORKDIR"]}/*") { "SERVER CLEANUP" }

  # generate the new key
  key = `#{gemstash_command("authorize")}`.lines.first.split(":")[1].strip
  STDERR.puts "Using GEM_HOST_API_KEY=#{key}"

  # generate the new thread and IO object
  io = nil
  STDERR.puts "Launching gemstash thread"
  thread = Thread.new do
    annotated_command(gemstash_command("start", "--no-daemonize")) do |io_obj|
      io = io_obj
      "GEMSTASH"
    end
  end

  await_port_status(true) # don't return until the new server is ready
  OpenStruct.new(thread: thread, io: io, key: key)
end

# load info from the gemspec.  Don't Gem::Specification load in this binding
# or else it will be immutable!  explicit subprocess avoids that problem
def load_gemspec(path)
  OpenStruct.new(
    name: `ruby -e "puts Gem::Specification.load('#{path}').name"`.strip,
    version: `ruby -e "puts Gem::Specification.load('#{path}').version"`.strip,
  )
end

def server_address
  "http://localhost:#{ENV['SERVER_PORT']}/private"
end

# get the gemspec file from a directory
def gemspec_of_dir(gem_dir)
  gemspec = gem_dir.glob("*.gemspec").first
  STDERR.puts "Found #{gemspec}: #{gemspec.exist?}"
  gemspec
end

# get gem information from a directory that contains it
def gem_info(gem_dir)
  gemspec = gemspec_of_dir(gem_dir)
  spec = load_gemspec(gemspec)
  STDERR.puts "It describes name=#{spec.name} version=#{spec.version}"
  [spec.name, spec.version]
end

# ask our local server if it has our gem
def gem_version_exists(name, version)
  result = `gem list -r --clear-sources --source #{server_address} --all --prerelease -e #{name}`
  result.lines.each { |l| STDERR.puts "GEM LIST: #{l}" }
  lines = result.lines.select { |l| l.start_with?(name) }
  return false if lines.empty?

  lines.first.match(/\(([^)]+)\)/)[1].split(", ").include?(version)
end

# gem existence wrapper but by directory instead
def gem_version_exists_by_dir(gem_dir)
  name, version = gem_info(gem_dir)
  gem_version_exists(name, version)
end

# push gem to local server
def publish_gem(gem_dir, key)
  gemspec = gem_dir.glob("*.gemspec").first
  name, version = gem_info(gem_dir)

  tmp_build_gem = Pathname.new(ENV["GEM_BUILD_DIR"]) + "tmp.gem"
  tmp_build_gem.unlink if tmp_build_gem.exist?
  return STDERR.puts "FAILED TO DELETE OLD TMP GEM" if tmp_build_gem.exist?

  Dir.chdir(gem_dir) do
    annotated_command(["gem", "build", "-o", tmp_build_gem.to_s, gemspec.to_s].shelljoin) { "GEM BUILD" }
  end
  return STDERR.puts "FAILED TO BUILD #{gemspec}" unless tmp_build_gem.exist?

  annotated_command(
    {"GEM_HOST_API_KEY" => key},
    ["gem", "push", "--host", server_address, tmp_build_gem.to_s].shelljoin
  ) { "GEM PUSH" }
  STDERR.puts "Completed gem push: #{gem_version_exists(name, version)}"
rescue Exception => e
  STDERR.puts "publish_gem(#{gem_dir}) FAILED: #{e}"
end


# Get the list of gems requested by the user and as a side effect print some
# warnings about whether the directories exist.  Also, convert them to full
# paths here because threads and Dir.chdir don't mix (unless you like warnings)
def specified_gems
  gem_basedir = ENV["LOCAL_GEMS_DIR"]
  STDERR.puts "Will look for gems relative to local mount volume #{gem_basedir}"
  Dir.chdir(gem_basedir) do
    gem_basedir_contents = Dir["*"]

    if gem_basedir_contents.size == 1 && gem_basedir_contents.first == ENV["EMPTINESS_CHECK"]
      nope("It appears that no gem directory was mounted.\n#{usage}")
    end

    ARGV.map { |d| Pathname.new(gem_basedir) + (d.end_with?("/") ? d : "#{d}/") }.each do |gemdir|
      what = "WARNING: requested gem dir '#{gemdir}'"
      next STDERR.puts "#{what} doesn't exist (yet?)" unless gemdir.exist?
      next STDERR.puts "#{what} is a file" if gemdir.file?
      next STDERR.puts "#{what} isn't a dir ???" unless gemdir.directory?
    end
  end

end

begin
  nope("No gem paths were specified\n#{usage}") if ARGV.empty?

  # read inputs and print warnings as appropriate
  gems = specified_gems

  stash_runner = run_gemstash

  Dir.chdir(ENV["LOCAL_GEMS_DIR"]) do
    Filewatcher.new(gems, interval: 0.7, immediate: true).watch do |changes|
      valid_gems = gems.select(&:exist?).map(&:realpath) # because maybe they were added

      # find out which gems were changed. on the first run, ALL of them are changed
      changed_gems = []
      changes.each do |filename, event|
        if filename.empty? && event.empty?  # "immediate" -- first time
          changed_gems = valid_gems
        else
          Pathname.new(filename).ascend { |v| changed_gems << v if valid_gems.include?(v) }
        end
      end
      STDERR.puts "Changed gems: #{changed_gems}"

      # can't push existing gems.  can't re-push yanked gems. can only reboot the server with blank config.
      if changed_gems.any? { |gem_dir| gem_version_exists_by_dir(gem_dir) }
        STDERR.puts("Rebooting server")
        Process.kill("KILL", stash_runner.io.pid)
        stash_runner.thread.exit
        stash_runner.thread.join
        stash_runner = run_gemstash
      end
      STDERR.puts("Publishing gems")
      changed_gems.each { |gem_dir| publish_gem(gem_dir, stash_runner.key) }
    end
  end

ensure
  stash_runner.join
end
