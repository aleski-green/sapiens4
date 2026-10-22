RSpec.describe 'Corpora workspace browser flows' do
  def probe(scenario)
    out, error, code = Contract.capture('node', 'spec/support/corpora-browser.cjs', scenario)
    expect(code).to eq(0), out + error
    JSON.parse(out)
  end

  it 'manages pairing for the chosen local corpora without changing selection' do
    result = probe('pairing-rows')
    expect(result).to include('column' => true, 'selected' => 'Home', 'title' => 'Edit Pairing', 'after' => 'New Pairing')
    expect(result['rows']).to eq([{'name' => 'Home', 'action' => 'New Pairing'}, {'name' => 'Studio', 'action' => nil}, {'name' => 'Second local', 'action' => 'Edit Pairing'}])
    expect(result['details']).to include('Second local', 'iPhone', 'iOS 26', 'Home Screen app', 'Paired', 'Last connected', 'Replace remote', 'Revoke remote')
    expect(result['details']).not_to include('Not recorded')
    expect(result['revoke']).to include('/cccccccc-cccc-4ccc-8ccc-cccccccccccc/api/remote/revoke')
  end

  it 'hides pairing for a device with only remote corpora' do
    expect(probe('pairing-only-remote')).to eq('column' => false, 'actions' => 0, 'requests' => 0)
  end

  it 'switches the interface without changing either corpora’s execution state' do
    expect(probe('switch')).to include('active' => 'Studio', 'status' => 'Paused', 'menuOpen' => true,
      'commands' => [], 'states' => %w[active paused])
  end

  it 'returns to local immediately without contacting the unreachable previous remote' do
    expect(probe('leave-unreachable')).to include('active' => 'Home', 'commands' => [],
      'states' => %w[active paused], 'notice' => nil, 'remoteRequests' => 0)
  end

  it 'does not pause the current corpora or change selection if the target cannot be reached' do
    expect(probe('unreachable')).to include('active' => 'Home', 'commands' => [], 'menuOpen' => true,
      'notice' => 'This device is unreachable. Try again later.')
  end

  it 'opens saved remote history immediately, blocks offline writes and reconnects without replaying them' do
    expect(probe('cached-offline')).to include('active' => 'Studio', 'status' => 'Offline · Read only',
      'reply' => 'Saved remote reply', 'draft' => 'Unsent draft', 'requests' => 0,
      'lifecycleDisabled' => true, 'writeError' => 'Offline — read only.', 'writes' => 0,
      'reconnected' => true, 'liveStatus' => 'Active', 'writesAfterReconnect' => 0)
  end

  it 'restores the saved selection, layout and draft before any host responds' do
    result = probe('restore')
    expect(result).to include('selected' => 'Home', 'status' => 'Offline · Read only')
    expect(result['preferences']).to include('selected' => 'last-chat', 'drafts' => {'last-chat' => 'Keep this draft'},
      'panes' => {'chat' => true, 'sidebar' => false})
  end

  it 'connects after saved credentials arrive even if the cached workspace requested data first' do
    expect(probe('resume-before-credentials')).to include('earlyError' => 'Connecting…',
      'transports' => [true], 'connected' => true, 'status' => 'Paused')
  end

  it 'requires installation on a phone before accessing saved connections or pairing' do
    %w[mobile android].each do |platform|
      expect(probe(platform)).to include('gate' => true, 'localVisible' => false, 'networkCalls' => 0,
        'credentialReads' => 0, 'workers' => ['/sw.js'])
    end
  end

  it 'offers only remote corpora on Linux without requiring desktop installation' do
    expect(probe('linux')).to include('gate' => false, 'localVisible' => false, 'empty' => true)
  end

  it 'addresses remote settings messages to that corpora’s ChiefSapi without changing selection' do
    result = probe('edit')
    expect(result['message']).to include('New name: Studio', 'Device name: Mac mini', 'Scope of operations: Studio tasks')
    expect(result['target']).to end_with('/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/api/agents/chief-b/messages')
    expect(result['selected']).to eq('Home')
    expect(result['actions']).to eq(['send'])
  end

  {'local' => ['Home', 'chief-a'], 'remote' => ['Studio', 'chief-b']}.each do |location, (name, chief)|
    it "activates a paused #{location} corpora before sending its settings message exactly once" do
      result = probe("edit-paused-#{location}")
      expect(result).to include('status' => 'active', 'actions' => %w[activate send],
        'writeTargets' => [name, name], 'selected' => 'Home', 'dialogOpen' => false)
      expect(result['target']).to end_with("/api/agents/#{chief}/messages")
      expect(result['sent']).to eq(result['message'])
    end
  end

  it 'keeps the settings draft and does not send when activation fails' do
    result = probe('edit-activation-failed')
    expect(result).to include('status' => 'paused', 'actions' => ['activate'], 'dialogOpen' => true,
      'feedback' => 'This device is unreachable. Try again later.')
    expect(result['draft']).to eq(result['message'])
  end

  it 'does not restore or activate an archived corpora when sending settings' do
    result = probe('edit-archived')
    expect(result).to include('status' => 'archived', 'actions' => [], 'dialogOpen' => true)
    expect(result['feedback']).to include('Restore this archived corpora')
    expect(result['draft']).to eq(result['message'])
  end

  it 'migrates existing trust and retains other corpora when a connection is forgotten' do
    expect(probe('storage')).to include('before' => ['Home'], 'after' => %w[Home Studio], 'remaining' => ['Home'])
  end
end
