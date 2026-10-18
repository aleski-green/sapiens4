require_relative 'support/relay'

RSpec.describe 'Installed app encrypted connection', :host do
  it 'keeps the replaced window disconnected instead of reclaiming the other window’s session' do
    relay = Relay.new
    peer = RemotePeer.new(script: 'app-remote-peer.cjs')
    invitation = host.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    peer.call('pair', invitation: invitation)
    pending = Contract.wait { host.api('GET', '/api/remote')['pending'] }
    host.api('POST', '/api/remote/approve', {peer: pending['peer']})
    Contract.wait { peer.call('status')['state'] == 'approved' }
    peer.call('open-window')
    2.times { expect(peer.call('request', path: '/api/state')['error']).to include('another window') }
    expect(peer.call('other-request', path: '/api/state')['status']).to eq(200)
  ensure
    peer.close if peer
    relay.close if relay
  end

  it 'pairs through host approval, restores trust, edits via ChiefSapi and controls lifecycle' do
    relay = Relay.new
    peer = RemotePeer.new(script: 'app-remote-peer.cjs')
    invitation = host.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    start = peer.call('pair', invitation: invitation)
    pending = Contract.wait { host.api('GET', '/api/remote')['pending'] }
    expect(start['code']).to eq(pending['confirmation_code'])
    host.api('POST', '/api/remote/approve', {peer: pending['peer']})
    result = Contract.wait { value = peer.call('status'); value if value['state'] != 'waiting' }
    expect(result['state']).to eq('approved'), result.inspect
    identity = host.state['corpora']['id']
    expect(peer.call('request', path: '/api/state')['body']['corpora']['id']).to eq(identity)
    expect(peer.call('restore')['id']).to eq(identity)
    metadata = peer.call('request', path: '/api/corpora')['body']
    expect(peer.call('request', path: "/api/agents/#{chief}/control", method: 'POST', body: {
      op: 'corpora_update', revision: metadata['revision'], name: 'Remote Studio', device: 'Host Mac', scope: 'Design work'
    })['status']).to eq(200)
    expect(host.api('GET', '/api/corpora')).to include('name' => 'Remote Studio', 'scope' => 'Design work')
    metadata = host.api('GET', '/api/corpora')
    expect(peer.call('request', path: '/api/corpora/lifecycle', method: 'PUT', body: {
      action: 'pause', revision: metadata['revision'], operation: SecureRandom.uuid
    })['body']['status']).to eq('paused')
    expect(host.state['pulse']['running']).to eq(false)
    expect(peer.call('request', path: '/api/host')['error']).to include('not allowed')
    host.api('POST', '/api/remote/revoke', {})
    peer.call('close')
    expect { peer.call('restore') }.to raise_error(/revoked/)
  ensure
    peer.close if peer
    relay.close if relay
  end
end
