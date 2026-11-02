require 'socket'

RSpec.describe 'Linux host launcher' do
  before do
    skip 'Linux launcher' unless RUBY_PLATFORM.include?('linux')
    @fixture = Host.new(start: false)
    @directory = Dir.mktmpdir('sapiens-linux-')
  end

  after do
    @fixture&.close
    FileUtils.remove_entry(@directory) if @directory
  end

  def launch(environment = {}, *arguments)
    child = Contract::Child.new('sh', File.join(Contract::ROOT, 'environments/linux/start.sh'),
      '--port', '0', '--desktop', *arguments,
      chdir: @directory, env: @fixture.environment.merge('XDG_DATA_HOME' => @directory, 'SAPIENS_DATA_DIR' => nil).merge(environment))
    url = nil
    Contract.wait(description: 'Linux host startup') do
      url = child.stdout[%r{Sapiens4: (http://127.0.0.1:\d+)}, 1]
    end
    code, state = Contract.http(url + '/api/state', 'GET')
    expect(code).to eq(200)
    yield child, state, url if block_given?
    child.input.close
    _, error, status = child.finish
    expect(status).to eq(0), error
    state.fetch('main_agent_id')
  ensure
    child&.close
  end

  it 'stores and reopens the same corpora under XDG_DATA_HOME' do
    chief = launch
    expect(File).to exist(File.join(@directory, 'sapiens4/corpora.sqlite3'))
    expect(launch).to eq(chief)
  end

  it 'ignores a relative XDG data path and uses the user data directory' do
    launch('XDG_DATA_HOME' => 'relative', 'HOME' => @directory)
    expect(File).to exist(File.join(@directory, '.local/share/sapiens4/corpora.sqlite3'))
    expect(File).not_to exist(File.join(@directory, 'relative'))
  end

  it 'honors the data directory environment override' do
    data = File.join(@directory, 'custom data')
    launch('SAPIENS_DATA_DIR' => data)
    expect(File).to exist(File.join(data, 'corpora.sqlite3'))
    expect(File).not_to exist(File.join(@directory, 'sapiens4'))
  end

  it 'gives an explicit data directory precedence over the environment' do
    data = File.join(@directory, 'explicit data')
    launch({'SAPIENS_DATA_DIR' => File.join(@directory, 'unused')}, '--data-dir', data)
    expect(File).to exist(File.join(data, 'corpora.sqlite3'))
    expect(File).not_to exist(File.join(@directory, 'unused'))
  end

  it 'provides Linux browser instructions and removes its private session on exit' do
    launch('TMPDIR' => @directory) do |_child, state, url|
      expect(state.fetch('computer')).to include('platform' => 'linux', 'backend' => 'headless')
      status, diagnostics = Contract.http(url + '/api/computer', 'GET')
      expect(status).to eq(200)
      expect(diagnostics).to include('backend' => 'headless', 'built' => true, 'trusted' => true, 'nativeDesktopAccess' => false)
      sessions = Dir.glob(File.join(@directory, 'sapiens-browser-*'))
      expect(sessions.size).to eq(1)
      expect(File.stat(sessions.first).mode & 0777).to eq(0700)
      expect(File.socket?(File.join(sessions.first, 'browser.sock'))).to eq(true)
      instructions = Dir.glob(File.join(@directory, '**/manifests/computer-use.md')).map { |path| File.read(path) }.join
      expect(instructions).to include('owned headless browser', 'exact draft')
    end
    expect(Dir.glob(File.join(@directory, 'sapiens-browser-*'))).to be_empty
  end

  it 'executes the published headless command in a provider turn and releases ownership' do
    @fixture.configure(rules: {'Assessing' => {actions: [
      {generated_command: 'computer', arguments: ['blindly', 'apps']}
    ]}})
    launch do |_child, state, url|
      owner = state.fetch('main_agent_id')
      status, response = Contract.http(url + "/api/agents/#{owner}/messages", 'POST', {text: 'Exercise the generated headless command'})
      expect(status).to eq(202), response.inspect
      call = Contract.wait(description: 'generated headless command') do
        @fixture.calls.find { |entry| entry.fetch('commands', []).any? }
      end
      result = call.fetch('commands').first
      expect(result.fetch('status')).to eq(0), result.inspect
      expect(JSON.parse(result.fetch('stdout'))).to eq('apps' => [])
      Contract.wait(description: 'headless turn completion') do
        current = Contract.http(url + '/api/state', 'GET')[1]
        current.fetch('turns').any? { |turn| turn['status'] == 'done' } && current.fetch('computer').fetch('owner').nil?
      end
    end
  end

  it 'closes its browser and temporary profile when the host exits' do
    skip 'Pinned browser binaries required' unless ENV['SAPIENS_TEST_HEADLESS_BROWSERS'] == '1'
    launch('TMPDIR' => @directory) do |_child, _state|
      socket = Dir.glob(File.join(@directory, 'sapiens-browser-*/browser.sock')).fetch(0)
      output, error, status = Contract.capture('sh', File.join(Contract::ROOT, 'environments/linux/headless.sh'), 'launch', 'Browser',
        env: {'SAPIENS_LINUX_BROWSER_SOCKET' => socket})
      expect(status).to eq(0), output + error
      expect(JSON.parse(output)).to include('launched' => true)
      expect(Dir.glob(File.join(@directory, 'playwright*'))).not_to be_empty
    end
    expect(Dir.glob(File.join(@directory, 'sapiens-browser-*'))).to be_empty
    expect(Dir.glob(File.join(@directory, 'playwright*'))).to be_empty
  end

  it 'shuts down with an incomplete local browser request still connected' do
    launch('TMPDIR' => @directory) do |_child, _state|
      client = UNIXSocket.new(Dir.glob(File.join(@directory, 'sapiens-browser-*/browser.sock')).fetch(0))
      client.write('["launch"')
      @incomplete_client = client
    end
    expect(@incomplete_client.read).to eq('')
    expect(Dir.glob(File.join(@directory, 'sapiens-browser-*'))).to be_empty
  ensure
    @incomplete_client&.close
  end
end

RSpec.describe 'Linux virtual execution' do
  it 'runs a command on a private software-rendered X server and preserves its exit status' do
    skip 'Virtual desktop dependencies required' unless ENV['SAPIENS_TEST_LINUX_VIRTUAL'] == '1'
    output, error, status = Contract.capture('sh', File.join(Contract::ROOT, 'environments/linux/virtual.sh'),
      'sh', '-c', 'xdpyinfo >/dev/null || exit 1; printf "%s %s %s\n" "$XDG_SESSION_TYPE" "$LIBGL_ALWAYS_SOFTWARE" "${WAYLAND_DISPLAY-unset}"; exit 23')
    expect(status).to eq(23), output + error
    expect(output).to eq("x11 1 unset\n")
  end

  it 'rejects an empty command before opening a virtual desktop' do
    skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
    _, error, status = Contract.capture('sh', File.join(Contract::ROOT, 'environments/linux/virtual.sh'))
    expect(status).to eq(64)
    expect(error).to include('Usage:')
  end

  it 'rejects invalid GNOME fixture arguments before starting services' do
    skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
    launcher = File.join(Contract::ROOT, 'spec/support/gnome-session.sh')
    _, error, status = Contract.capture('sh', launcher)
    expect(status).to eq(64)
    expect(error).to include('Usage:')
    _, error, status = Contract.capture('sh', launcher, 'true', env: {'SAPIENS_TEST_SCALE' => '3'})
    expect(status).to eq(64)
    expect(error).to include('Fixture scale must be 1 or 2')
  end
end

RSpec.describe 'Linux computer diagnostics' do
  it 'reports a missing native backend without acquiring the computer or starting a turn' do
    skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
    fixture = Host.new(environment: {'SAPIENS_LINUX_BACKEND' => 'native', 'SAPIENS_BLINDLY_BINARY' => '/missing/sapiens-driver'})
    expect(fixture.api('GET', '/api/computer')).to include('backend' => 'native', 'built' => false,
      'error' => 'Computer backend is not built')
    expect(fixture.state.fetch('computer').fetch('owner')).to be_nil
    expect(fixture.state.fetch('turns')).to be_empty
  ensure
    fixture&.close
  end
end
