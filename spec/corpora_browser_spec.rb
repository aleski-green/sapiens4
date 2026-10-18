RSpec.describe 'Corpora workspace browser flows' do
  def probe(scenario)
    out, error, code = Contract.capture('node', 'spec/support/corpora-browser.cjs', scenario)
    expect(code).to eq(0), out + error
    JSON.parse(out)
  end

  it 'pauses the previous corpora, activates the selected one and leaves the selector open' do
    expect(probe('switch')).to include('active' => 'Studio', 'status' => 'Active', 'menuOpen' => true,
      'commands' => [{'target' => 'Home', 'action' => 'pause'}, {'target' => 'Studio', 'action' => 'activate'}])
  end

  it 'does not pause the current corpora or change selection if the target cannot be reached' do
    expect(probe('unreachable')).to include('active' => 'Home', 'commands' => [], 'menuOpen' => true,
      'notice' => 'This device is unreachable. Try again later.')
  end

  it 'restores the saved selection, layout and draft before any host responds' do
    result = probe('restore')
    expect(result).to include('selected' => 'Home', 'status' => 'Connecting…')
    expect(result['preferences']).to include('selected' => 'last-chat', 'drafts' => {'last-chat' => 'Keep this draft'},
      'panes' => {'chat' => true, 'sidebar' => false})
  end

  it 'requires installation on a phone before accessing saved connections or pairing' do
    expect(probe('mobile')).to include('gate' => true, 'localVisible' => false, 'networkCalls' => 0,
      'credentialReads' => 0, 'workers' => ['/sw.js'])
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
