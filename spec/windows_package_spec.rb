require_relative 'support/desktop'
require_relative 'support/relay'

RSpec.describe 'Packaged Windows application', :windows do
  it 'opens the shipped window and sends a message using its embedded runtime', :desktop do
    skip 'Windows package required' unless Gem.win_platform? && ENV['SAPIENS_TEST_WINDOWS_PACKAGE']
    @host = Host.new(start: false)
    binary = File.join(ENV.fetch('SAPIENS_TEST_WINDOWS_PACKAGE'), 'Sapiens4.exe')
    app = Contract::Child.new(binary, '--data-dir', host.root,
      env: host.environment.merge('SAPIENS_PYTHON' => nil, 'SAPIENS_RUNTIME_DIR' => nil))
    # The packaged window has no test API. Discover it through the native process.
    @desktop = Desktop.new(process: app, ready: false)
    desktop.fill('Message ChiefSapi', 'Hello from the packaged app')
    desktop.press('Send message')
    expect(desktop.see('Contract test reply')).to include('Hello from the packaged app')
  ensure
    begin
      if app && Gem.win_platform? && @desktop
        desktop.key('alt+F4')
      elsif app && !Gem.win_platform?
        app.signal('TERM')
      end
    ensure
      app&.close
    end
  end

  it 'preserves remote authority across an embedded-runtime restart' do
    skip 'Windows package required' unless Gem.win_platform? && ENV['SAPIENS_TEST_WINDOWS_PACKAGE']
    runtime = File.join(ENV.fetch('SAPIENS_TEST_WINDOWS_PACKAGE'), 'runtime')
    @host = Host.new(repo: runtime, python: File.join(runtime, 'python', 'python.exe'),
      environment: {'PYTHONPATH' => nil, 'PYTHONHOME' => nil})
    relay = Relay.new
    peer = PairedDevice.new
    invitation = host.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    peer.pair(invitation)
    pending = Contract.wait { host.api('GET', '/api/remote')['pending'] }
    host.api('POST', '/api/remote/approve', {peer: pending['peer']})
    expect(peer.receive['paired']).to eq(true)
    identity = host.state['corpora']['id']
    expect(peer.request('/api/state')['body']['corpora']['id']).to eq(identity)
    host.restart
    expect(peer.request('/api/state')['body']['corpora']['id']).to eq(identity)
    host.api('POST', '/api/remote/revoke', {})
    expect(host.api('GET', '/api/remote')['paired']).to eq(false)
  ensure
    peer&.close
    @host&.close
    relay&.close
  end
end
