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

  it 'pauses the previous corpora, activates the selected one and leaves the selector open' do
    expect(probe('switch')).to include('active' => 'Studio', 'status' => 'Active', 'menuOpen' => true,
      'commands' => [{'target' => 'Home', 'action' => 'pause'}, {'target' => 'Studio', 'action' => 'activate'}])
  end

  it 'does not pause the current corpora or change selection if the target cannot be reached' do
    expect(probe('unreachable')).to include('active' => 'Home', 'commands' => [], 'menuOpen' => true,
      'notice' => 'This device is unreachable. Try again later.')
  end

  it 'opens local corpora after explicit recovery from an unreachable current remote' do
    result = probe('recover-offline')
    expect(result).to include('offered' => true, 'before' => 'Studio', 'commandsBefore' => [],
      'active' => 'Home', 'localStatus' => 'active', 'remoteStatus' => 'active',
      'saved' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'commands' => [{'target' => 'Home', 'action' => 'activate'}])
    expect(result['warning']).to include('may still be running')
    expect(result['notice']).to include('Studio could not be paused')
    expect(result['draft']).to eq('drafts' => {'chief-b' => 'Keep remote draft'})
  end

  it 'keeps the remote selected and performs no lifecycle writes when recovery is cancelled' do
    expect(probe('recover-cancel')).to include('offered' => true, 'active' => 'Studio',
      'localStatus' => 'paused', 'commands' => [])
  end

  it 'rechecks the local destination before recovering and preserves selection if it fails' do
    expect(probe('recover-local-failed')).to include('offered' => true, 'active' => 'Studio',
      'commands' => [], 'notice' => 'Local host unavailable')
  end

  it 'retains an uncertain remote pause across reload and reconciles it without replay before returning' do
    result = probe('recover-lost-pause')
    expect(result).to include('offered' => true, 'active' => 'Home', 'restored' => 'Home',
      'localPaused' => 'paused', 'returned' => 'Studio', 'reconciled' => true,
      'remaining' => nil, 'remotePauses' => 1)
    expect(result.fetch('deferred').fetch('pending')).to include('action' => 'pause',
      'key' => 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
  end

  it 'does not bypass an unresolved local activation during remote recovery' do
    expect(probe('recover-local-pending')).to include('offered' => false, 'active' => 'Studio',
      'localStatus' => 'paused', 'commands' => [])
  end

  it 'restores the saved selection, layout and draft before any host responds' do
    result = probe('restore')
    expect(result).to include('selected' => 'Home', 'status' => 'Connecting…')
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
