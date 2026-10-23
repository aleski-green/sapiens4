require_relative 'host'
require 'socket'

class UpdaterEnvironment
  attr_reader :root, :home, :data, :old, :revision, :url, :environment, :host
  def initialize
    @host = Host.new(start: false)
    @root = host.root
    @home, @data = File.join(root, 'managed'), File.join(root, 'data')
    FileUtils.mkdir_p([home, data, File.join(home, 'backups')])
    @upstream = File.join(root, 'upstream')
    @old_root = File.join(home, 'releases', 'old')
    git('clone', '--quiet', '--shared', Contract::ROOT, @upstream)
    git('-C', @upstream, 'checkout', '-B', 'main')
    git('clone', '--quiet', '--shared', @upstream, @old_root)
    %w[web license].each { |folder| FileUtils.cp_r(File.join(Contract::ROOT, 'libs4', folder), File.join(@old_root, 'libs4')) }
    old_sha = git('-C', @old_root, 'rev-parse', 'HEAD').strip
    File.write(File.join(@upstream, 'fixture-revision'), 'new release')
    git('-C', @upstream, 'add', 'fixture-revision')
    git('-C', @upstream, '-c', 'user.name=Contract fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Fixture release')
    @revision = git('-C', @upstream, 'rev-parse', 'HEAD').strip
    @old = {'root' => @old_root, 'sha' => old_sha}
    socket = TCPServer.new('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    @url = "http://127.0.0.1:#{port}"
    Contract.atomic_json(File.join(home, 'config.json'), {data: data, port: port, legacy_root: @old_root})
    Contract.atomic_json(File.join(home, 'current.json'), old)
    tools = File.join(root, 'tools')
    FileUtils.mkdir_p([tools, File.join(root, 'sdk')])
    %w[git xcrun cargo codesign ditto].each do |name|
      path = File.join(tools, name)
      File.write(path, "#!#{RbConfig.ruby}\nload #{File.join(__dir__, 'build_tool.rb').inspect}\n")
      File.chmod(0755, path)
    end
    FileUtils.cp(File.join(Contract::ROOT, 'blindly4', 'macos/build.sh'), File.join(root, 'blindly-build.sh'))
    @environment = host.environment.merge('PATH' => tools + File::PATH_SEPARATOR + ENV.fetch('PATH'),
      'SAPIENS_BUILD_ENV' => root, 'SAPIENS_FIXTURE_UPSTREAM' => @upstream, 'SAPIENS_REAL_GIT' => `command -v git`.strip,
      'SAPIENS_FIXTURE_LIBS' => File.join(Contract::ROOT, 'libs4'))
    configure
  end
  def git(*args)
    output, error, code = Contract.capture('git', *args)
    raise error unless code == 0
    output
  end
  def configure(**fields)
    @settings = (@settings || {}).merge(fields)
    Contract.atomic_json(File.join(root, 'build.json'), @settings)
  end
  def run(action, timeout: 40)
    Contract.capture(Contract::PYTHON, File.join(Contract::ROOT, 'macos/updater.py'), '--home', home, action,
      env: environment, timeout: timeout)
  end
  def start(activate: true)
    activation = File.join(home, 'activate-fixture')
    File.write(activation, '') if activate
    @server = Contract::Child.new(Contract::PYTHON, File.join(Contract::ROOT, 'macos/updater.py'),
      '--home', home, 'serve', '--root', old['root'], '--activation', activation,
      env: environment, chdir: old['root'])
    Contract.wait(description: 'managed server health') do
      begin
        health = Contract.http(url + '/api/health', 'GET')[1]
        health['desktop_active'] == activate
      rescue Errno::ECONNREFUSED
        false
      end
    end
    activation
  end
  def current; JSON.parse(File.read(File.join(home, 'current.json'))); end
  def status; JSON.parse(File.read(File.join(home, 'status.json'))); end
  def bundle(name, sha, valid: true)
    path = File.join(root, name + '.app')
    FileUtils.mkdir_p([File.join(path, 'Contents/MacOS'), File.join(path, 'Contents/Resources')])
    {'Info.plist' => {'CFBundleIdentifier' => 'com.sapiens4.desktop', 'SapiensDesktopRevision' => sha},
     'Resources/Launcher.plist' => {'ManagedHome' => valid ? home : '/wrong-installation'}}.each do |file, values|
      File.write(File.join(path, 'Contents', file), '<?xml version="1.0"?><plist version="1.0"><dict>' +
        values.map { |key, value| "<key>#{key}</key><string>#{value}</string>" }.join + '</dict></plist>')
    end
    binary = File.join(path, 'Contents/MacOS/Sapiens4')
    File.write(binary, "#!/bin/sh\nexit 0\n")
    File.chmod(0755, binary)
    path
  end
  def desktop(candidate_valid: true)
    installed = bundle('Installed', 'a' * 40)
    candidate = bundle('Candidate', old['sha'], valid: candidate_valid)
    config = JSON.parse(File.read(File.join(home, 'config.json'))).merge('app' => installed)
    Contract.atomic_json(File.join(home, 'config.json'), config)
    Contract.atomic_json(File.join(home, 'current.json'), old.merge('desktop' => candidate))
    configure(revision: old['sha'])
    [installed, candidate]
  end
  def close
    begin
      health = Contract.http(url + '/api/health', 'GET')[1]
      Process.kill('TERM', health.fetch('desktop_pid'))
      Contract.wait(description: 'managed server shutdown') do
        begin
          Contract.http(url + '/api/health', 'GET')
          false
        rescue Errno::ECONNREFUSED, EOFError, Errno::ECONNRESET
          true
        end
      end
    rescue Errno::ECONNREFUSED, Errno::ESRCH
    ensure
      @server.close if @server
      host.close
    end
  end
end
