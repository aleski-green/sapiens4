RSpec.describe 'Ubuntu headless package' do
  before(:context) do
    skip 'Headless package qualification required' unless ENV['SAPIENS_TEST_HEADLESS_PACKAGE']
    @directory = Dir.mktmpdir('sapiens-headless-package-')
    output, error, status = Contract.capture('dpkg-deb', '--raw-extract', ENV.fetch('SAPIENS_TEST_HEADLESS_PACKAGE'), @directory, timeout: 120)
    expect(status).to eq(0), output + error
    @runtime = File.join(@directory, 'opt/sapiens4-headless')
  end

  after(:context) { FileUtils.remove_entry(@directory) if @directory }

  it 'contains a private-data-free runtime without privileged installation hooks' do
    expect(Dir.children(File.join(@directory, 'DEBIAN'))).to contain_exactly('control')
    expect(Dir.glob(File.join(@runtime, '**/corpora.sqlite3'))).to be_empty
    expect(Dir.glob(File.join(@directory, '**/gnome-shell/extensions/*'))).to be_empty
    output, error, status = Contract.capture(File.join(@runtime, 'environments/linux/headless.sh'), 'schema', env: {'PATH' => '/usr/bin:/bin'})
    expect(status).to eq(0), output + error
    expect(JSON.parse(output)).to include('platform' => 'linux', 'backend' => 'playwright')
  end

  it 'starts the packaged host, completes a turn, and serves the packaged workspace' do
    fixture = Host.new(repo: @runtime, command: ['sh', File.join(@runtime, 'environments/linux/start.sh')],
      environment: {'PATH' => '/usr/bin:/bin', 'SAPIENS_REPOSITORY' => nil})
    owner = fixture.state.fetch('main_agent_id')
    expect(fixture.turn(fixture.submit(owner, 'Packaged headless host')).fetch('output')).to eq('Contract test reply')
    %w[/workspace/ /workspace/app.js /workspace/guest.js /workspace/styles.css /remote-vendor.js].each do |path|
      expect(fixture.request('GET', path).first).to eq(200)
    end
  ensure
    fixture&.close
  end

  it 'launches both bundled sandboxed browsers without an installed Node runtime' do
    %w[Browser Firefox].each do |browser|
      Dir.mktmpdir('sapiens-package-browser-') do |directory|
        environment = {'PATH' => '/usr/bin:/bin', 'SAPIENS_LINUX_BROWSER_SOCKET' => File.join(directory, 'browser.sock'),
          'PLAYWRIGHT_BROWSERS_PATH' => nil}
        launcher = File.join(@runtime, 'environments/linux/headless.sh')
        server = Contract::Child.new(launcher, 'serve', env: environment)
        Contract.wait(description: 'packaged browser readiness') { server.stdout.include?('READY') }
        output, error, status = Contract.capture(launcher, 'launch', browser, env: environment)
        expect(status).to eq(0), output + error
        expect(JSON.parse(output)).to include('launched' => true, 'backend' => 'playwright')
      ensure
        server&.signal('TERM')
        server&.close
      end
    end
  end
end

RSpec.describe 'Ubuntu headless package lifecycle' do
  it 'installs, reinstalls and purges through apt without losing user data' do
    fixture = nil
    administration = {'PATH' => '/usr/sbin:/usr/bin:/sbin:/bin'}
    skip 'Disposable package-test filesystem required' unless ENV['SAPIENS_TEST_HEADLESS_PACKAGE_LIFECYCLE'] == '1' && File.file?('/run/sapiens-package-test')
    package = ENV.fetch('SAPIENS_TEST_HEADLESS_PACKAGE')
    expect(Contract.capture('dpkg-query', '-W', 'sapiens4-headless').last).not_to eq(0)
    data = File.join(Dir.home, '.local/share/sapiens4')
    FileUtils.mkdir_p(data)
    marker = File.join(data, 'qualification-marker')
    File.write(marker, 'Preserve user data')
    2.times do
      output, error, status = Contract.capture('apt-get', '-o', 'APT::Sandbox::User=root', '--yes', '--no-install-recommends',
        '--reinstall', 'install', package, timeout: 300, env: administration)
      expect(status).to eq(0), output + error
      fixture = Host.new(repo: '/opt/sapiens4-headless', command: ['/usr/bin/sapiens4-headless'],
        environment: {'PATH' => '/usr/bin:/bin', 'SAPIENS_REPOSITORY' => nil})
      expect(fixture.state.fetch('main_agent_id')).not_to be_empty
      fixture.close
      fixture = nil
      expect(File.read(marker)).to eq('Preserve user data')
      expect(Dir.glob(File.join(Dir.home, '.local/share/gnome-shell/extensions/*'))).to be_empty
    end
    output, error, status = Contract.capture('dpkg', '--purge', 'sapiens4-headless', timeout: 120, env: administration)
    expect(status).to eq(0), output + error
    expect(File).not_to exist('/usr/bin/sapiens4-headless')
    expect(File.read(marker)).to eq('Preserve user data')
  ensure
    fixture&.close
    if marker
      Contract.capture('dpkg', '--purge', 'sapiens4-headless', timeout: 120, env: administration)
      FileUtils.rm_f(marker)
    end
  end
end
