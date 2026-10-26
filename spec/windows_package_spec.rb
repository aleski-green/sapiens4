require_relative 'support/relay'

RSpec.describe 'Packaged Windows remote control', :windows do
  it 'renders the shipped desktop shell and isolated browser with its embedded runtime' do
    skip 'Windows desktop integration' unless Gem.win_platform?
    @host = Host.new(start: false)
    package = ENV.fetch('SAPIENS_TEST_WINDOWS_PACKAGE')
    report = File.join(host.root, 'smoke.json')
    out, error, code = Contract.capture(File.join(package, 'Sapiens4.exe'),
      '--data-dir', host.root, '--smoke-report', report, timeout: 90,
      env: host.environment.merge('SAPIENS_PYTHON' => nil, 'SAPIENS_RUNTIME_DIR' => nil))
    expect(code).to eq(0), out + error
    expect(JSON.parse(File.read(report))).to include('ok' => true, 'nativeBrowser' => true, 'groupBrowser' => true)
  ensure
    @host.close if @host
  end

  it 'pairs and reconnects using only the shipped Python runtime and libraries' do
    skip 'Windows desktop integration' unless Gem.win_platform?
    runtime = File.join(ENV.fetch('SAPIENS_TEST_WINDOWS_PACKAGE'), 'runtime')
    @host = Host.new(repo: runtime, python: File.join(runtime, 'python', 'python.exe'),
      environment: {'PYTHONPATH' => nil, 'PYTHONHOME' => nil})
    relay = Relay.new
    peer = RemotePeer.new(script: 'app-remote-peer.cjs')
    invitation = host.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    start = peer.call('pair', invitation: invitation)
    pending = Contract.wait { host.api('GET', '/api/remote')['pending'] }
    expect(start['code']).to eq(pending['confirmation_code'])
    host.api('POST', '/api/remote/approve', {peer: pending['peer']})
    Contract.wait { peer.call('status')['state'] == 'approved' }
    identity = host.state['corpora']['id']
    expect(peer.call('request', path: '/api/state')['body']['corpora']['id']).to eq(identity)
    host.restart
    expect(peer.call('restore')['id']).to eq(identity)
    expect(peer.call('request', path: '/api/state')['status']).to eq(200)
    host.api('POST', '/api/remote/revoke', {})
    Contract.wait { peer.call('saved')['count'] == 0 }
    expect(peer.call('saved')['count']).to eq(0)
  ensure
    peer.close if peer
    @host.close if @host
    relay.close if relay
  end
end
