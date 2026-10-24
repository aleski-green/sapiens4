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
    observed = JSON.parse(File.read(report))
    expect(observed).to include('ok' => true, 'nativeBrowser' => true, 'appIcon' => true)
    expect(observed['shell']).to include('composer' => true, 'bridge' => true)
    expect(observed['shell']['agents']).to be > 0
    expect(observed['group']).to include('rendered' => true, 'turns' => 0)
    expect(observed['group']['tabs'].map { |tab| tab['title'] }).to include('Group browser smoke')
    expect(observed['themes'].size).to eq(12)
    expect(observed['themes'].map { |row| [row['kind'], row['mode']] }).to eq(
      %w[blank text html original].flat_map { |kind| %w[dark light dark].map { |mode| [kind, mode] } })
    observed['themes'].each do |row|
      dark = row['mode'] == 'dark'
      authored = row['kind'] == 'html'
      original = row['kind'] == 'original'
      expect(row).to include('webMessage' => false, 'hostObjects' => false)
      expect(row['caption']['result']).to be >= 0
      expect(row['caption']['enabled']).to eq(dark ? 1 : 0)
      expect(row['caption']['icon']).to eq(dark ? -15_263_977 : -1)
      expect(row['background']).to eq(dark && !authored && !original ? -14_606_047 : -1)
      expect(row['rendered']).to eq('dark' => dark,
        'background' => original ? 'rgba(0, 0, 0, 0)' : authored ? 'rgb(18, 52, 86)' : dark ? 'rgb(33, 33, 33)' : 'rgb(255, 255, 255)',
        'ink' => original ? 'rgb(0, 0, 0)' : authored ? 'rgb(171, 205, 239)' : dark ? 'rgb(236, 236, 236)' : 'rgb(32, 32, 32)')
    end
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
