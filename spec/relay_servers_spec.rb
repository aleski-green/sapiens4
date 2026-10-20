require_relative 'support/relay'

RSpec.describe 'App-wide relay selection', :host do
  def catalogue; host.api('GET', '/api/host/relays'); end
  def change(**data)
    host.api('POST', '/api/host/relays', {revision: catalogue['revision']}.merge(data))
  end
  def connection(relay = 'https://relay.example', token = 't' * 32)
    {format: 'sapiens-relay-connection-v1', relay: relay, token: token}
  end
  def add(name = 'My relay', config = connection)
    change(action: 'save', name: name, connection: config)['servers'].reverse.find { |row| row['name'] == name }['id']
  end

  it 'offers one beta, keeps Utana inactive after edits and restore, and requires beta acceptance' do
    expect(catalogue).to include('selected' => 'sapiens-beta', 'beta_accepted' => false)
    expect(catalogue['servers']).to include(hash_including('id' => 'sapiens-beta', 'address' => 'https://remote-relay.sapiens4.ai/beta', 'available' => true),
      hash_including('id' => 'utana-beta', 'address' => 'https://remote-relay.utana.group/beta', 'available' => false))
    expect(host.request('POST', '/api/remote/pair', {saved: true}).first).to eq(409)
    change(action: 'save', id: 'utana-beta', name: 'Utana later', connection: connection)
    change(action: 'archive', id: 'utana-beta')
    change(action: 'restore', id: 'utana-beta')
    expect(catalogue['servers'].find { |row| row['id'] == 'utana-beta' }).to include('available' => false, 'archived' => false)
    expect(host.request('POST', '/api/host/relays', {revision: catalogue['revision'], action: 'switch', id: 'utana-beta', confirm_revoke: true}).first).to eq(409)
    expect(change(action: 'accept-beta', accepted: true)['beta_accepted']).to eq(true)
  end

  it 'saves and edits private JSON without selecting it, archives, restores and survives restart' do
    id = add
    expect(catalogue['selected']).to eq('sapiens-beta')
    expect(JSON.generate(catalogue)).not_to include('t' * 32, 'token')
    expect(host.api('GET', '/api/host/relays/' + id)['connection']).to eq(connection.transform_keys(&:to_s))
    change(action: 'save', id: id, name: 'Office', connection: connection('https://office.example'))
    change(action: 'archive', id: id)
    host.restart
    expect(catalogue['servers']).to include(hash_including('id' => id, 'name' => 'Office', 'archived' => true))
    expect(change(action: 'restore', id: id)['servers']).to include(hash_including('id' => id, 'archived' => false))
    expect(File.stat(File.join(host.root, 'host-corpora.json')).mode & 0o777).to eq(0o600) unless Gem.win_platform?
  end

  it 'rejects invalid connections and stale writes without altering the active server' do
    revision = catalogue['revision']
    ['http://public.example', 'https://relay.example/beta', 'https://user:pass@relay.example'].each do |relay|
      expect(host.request('POST', '/api/host/relays', {revision: revision, action: 'save', name: 'Invalid', connection: connection(relay)}).first).to eq(409)
    end
    add
    expect(host.request('POST', '/api/host/relays', {revision: revision, action: 'archive', id: 'utana-beta'}).first).to eq(409)
    expect(catalogue['selected']).to eq('sapiens-beta')
    expect(host.request('POST', '/api/host/relays', {revision: catalogue['revision'], action: 'archive', id: 'sapiens-beta'}).first).to eq(409)
  end

  it 'requires confirmation for switching and active connection edits but not for a rename' do
    id = add
    expect(host.request('POST', '/api/host/relays', {revision: catalogue['revision'], action: 'switch', id: id}).first).to eq(409)
    expect(catalogue['selected']).to eq('sapiens-beta')
    expect(change(action: 'switch', id: id, confirm_revoke: true)).to include('selected' => id, 'reset' => true)
    expect(change(action: 'save', id: id, name: 'Renamed', connection: connection)['reset']).to eq(false)
    revised = connection('https://new.example')
    expect(host.request('POST', '/api/host/relays', {revision: catalogue['revision'], action: 'save', id: id, name: 'Renamed', connection: revised}).first).to eq(409)
    expect(host.api('GET', '/api/host/relays/' + id)['connection']['relay']).to eq('https://relay.example')
    expect(change(action: 'save', id: id, name: 'Renamed', connection: revised, confirm_revoke: true)['reset']).to eq(true)
    host.restart
    expect(catalogue['selected']).to eq(id)
    expect(host.api('GET', '/api/host/relays/' + id)['connection']['relay']).to eq('https://new.example')
  end

  it 'migrates existing setup without revocation, then revokes all local devices and native remote connections even offline' do
    relay = Relay.new
    other = Host.new
    device = RemotePeer.new(script: 'app-remote-peer.cjs')
    invitation = host.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    device.call('pair', invitation: invitation)
    pending = Contract.wait { host.api('GET', '/api/remote')['pending'] }
    host.api('POST', '/api/remote/approve', {peer: pending['peer']})
    Contract.wait { device.call('status')['state'] == 'approved' }
    child = nil
    if host.api('GET', '/api/host')['local_available']
      child = host.api('POST', '/api/host/local', {name: 'Second'}, status: 201)
      host.api('POST', "/api/host/corpora/#{child['id']}/api/remote/pair", {relay: relay.url, token: relay.token})
    end
    incoming = other.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    waiting = host.api('POST', '/api/host/pair', incoming, status: 202)
    pending = Contract.wait { other.api('GET', '/api/remote')['pending'] }
    other.api('POST', '/api/remote/approve', {peer: pending['peer']})
    Contract.wait { host.api('GET', '/api/host/pair/' + waiting['id'])['state'] == 'approved' }
    old = catalogue['selected']
    expect(catalogue['servers'].find { |row| row['id'] == old }['address']).to eq(relay.url)
    expect(host.api('GET', '/api/remote')['paired']).to eq(true)
    expect(device.call('request', path: '/api/state')['status']).to eq(200)
    new_id = add
    expect(host.api('GET', '/api/remote')['paired']).to eq(true)
    host.restart # Secondary local corpora has not been opened after this restart.
    relay.close; relay = nil
    expect(change(action: 'switch', id: new_id, confirm_revoke: true)['reset']).to eq(true)
    expect(host.api('GET', '/api/remote')).to include('enabled' => false, 'paired' => false)
    if child
      expect(host.api('GET', "/api/host/corpora/#{child['id']}/api/remote")['enabled']).to eq(false)
    end
    expect(host.api('GET', '/api/host')['corpora'].map { |row| row['location'] }).not_to include('Remote')
    expect(host.request('GET', "/api/host/corpora/#{other.state['corpora']['id']}/api/state").first).to eq(404)
    host.restart
    expect(host.api('GET', '/api/remote')['enabled']).to eq(false)
    expect(catalogue['selected']).to eq(new_id)
    expect(host.api('GET', '/api/host')['corpora'].map { |row| row['location'] }).not_to include('Remote')
  ensure
    device.close if device
    other.close if other
    relay.close if relay
  end

  it 'cancels an incoming pairing so delayed approval cannot restore a removed connection' do
    relay = Relay.new
    other = Host.new
    invitation = other.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    waiting = host.api('POST', '/api/host/pair', invitation, status: 202)
    pending = Contract.wait { other.api('GET', '/api/remote')['pending'] }
    id = add
    change(action: 'switch', id: id, confirm_revoke: true)
    other.api('POST', '/api/remote/approve', {peer: pending['peer']})
    expect(host.api('GET', '/api/host/pair/' + waiting['id'])['state']).to eq('cancelled')
    expect(host.api('GET', '/api/host')['corpora'].map { |row| row['location'] }).not_to include('Remote')
  ensure
    other.close if other
    relay.close if relay
  end

  it 'can return to a beta after switching away while its old mailbox was unreachable' do
    relay = Relay.new(beta: true)
    id = add('Local beta', {format: 'sapiens-relay-connection-v1', relay: relay.url, beta: true})
    change(action: 'switch', id: id, confirm_revoke: true)
    change(action: 'accept-beta', accepted: true)
    old = host.api('POST', '/api/remote/pair', {saved: true}, status: 201)['qr']
    relay.stop
    other = add('Other relay')
    change(action: 'switch', id: other, confirm_revoke: true)
    private_state = File.read(File.join(host.root, 'host-corpora.json'))
    expect(private_state).not_to include(old['secret'], old['token'])
    host.restart
    relay.start
    change(action: 'switch', id: id, confirm_revoke: true)
    change(action: 'accept-beta', accepted: true)
    replacement = host.api('POST', '/api/remote/pair', {saved: true}, status: 201)['qr']
    expect(replacement['room']).not_to eq(old['room'])
    expect(relay.request('GET', "/api/rooms/#{old['room']}/messages", nil, bearer: old['token']).first).to eq(401)
  ensure
    relay.close if relay
  end

  it 'finishes an interrupted committed switch before restoring old trust on startup' do
    relay = Relay.new
    host.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)
    id = add
    host.stop
    path = File.join(host.root, 'host-corpora.json')
    saved = JSON.parse(File.read(path))
    saved['relay_servers'].merge!('selected' => id, 'reset_pending' => true)
    File.write(path, JSON.generate(saved))
    host.start
    expect(host.api('GET', '/api/remote')).to include('enabled' => false, 'configured_relay' => 'https://relay.example')
    expect(catalogue['selected']).to eq(id)
    host.restart
    expect(host.api('GET', '/api/remote')['enabled']).to eq(false)
  ensure
    relay.close if relay
  end
end

RSpec.describe 'Opt-in public beta relay' do
  it 'does not allow public provisioning unless beta is enabled' do
    relay = Relay.new
    expect(relay.request('POST', '/beta/api/rooms', {}, bearer: '').first).to eq(404)
    expect(relay.request('POST', '/api/rooms', {}, bearer: '').first).to eq(401)
  ensure
    relay.close if relay
  end

  it 'creates private mailboxes without sharing admin credentials and bounds public creation' do
    relay = Relay.new(beta: true)
    host = Host.new
    peer = RemotePeer.new
    identity = host.api('GET', '/api/remote')
    body = {public_id: identity['public_id'], corpora_id: identity['corpora']['id'], public_key: peer.call('keys')['public']}
    first = relay.request('POST', '/beta/api/rooms', body, bearer: '')
    expect(first.first).to eq(200)
    expect(JSON.generate(first[1])).not_to include(relay.token)
    expect(relay.request('POST', '/beta/api/rooms', body, bearer: '').first).to eq(409)
    expect(relay.request('DELETE', '/api/rooms/' + first[1]['room'], nil, bearer: first[1]['desktop']).first).to eq(200)
    9.times do
      code, room = relay.request('POST', '/beta/api/rooms', body, bearer: '')
      expect(code).to eq(200)
      relay.request('DELETE', '/api/rooms/' + room['room'], nil, bearer: room['desktop'])
    end
    expect(relay.request('POST', '/beta/api/rooms', body, bearer: '').first).to eq(429)
    expect(relay.request('POST', '/api/rooms', {}, bearer: '').first).to eq(401)
  ensure
    peer.close if peer
    host.close if host
    relay.close if relay
  end

  it 'pairs a desktop using the beta connection without an admin token in its setup or QR' do
    relay = Relay.new(beta: true)
    host = Host.new
    config = {format: 'sapiens-relay-connection-v1', relay: relay.url, beta: true}
    state = host.api('GET', '/api/host/relays')
    state = host.api('POST', '/api/host/relays', revision: state['revision'], action: 'save', name: 'Test beta', connection: config)
    id = state['servers'].find { |row| row['name'] == 'Test beta' }['id']
    state = host.api('POST', '/api/host/relays', revision: state['revision'], action: 'switch', id: id, confirm_revoke: true)
    host.api('POST', '/api/host/relays', revision: state['revision'], action: 'accept-beta', accepted: true)
    invitation = host.api('POST', '/api/remote/pair', {saved: true}, status: 201)['qr']
    expect(invitation['relay']).to eq(relay.url)
    expect(JSON.generate(invitation)).not_to include(relay.token)
    expect(File.read(File.join(host.root, 'remote-relay.json'))).not_to include(relay.token)
  ensure
    host.close if host
    relay.close if relay
  end
end
