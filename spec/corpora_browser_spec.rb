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
    expect(probe('mobile')).to include('gate' => true, 'localVisible' => false, 'networkCalls' => 0)
  end

  it 'offers only remote corpora on Linux without requiring desktop installation' do
    expect(probe('linux')).to include('gate' => false, 'localVisible' => false, 'empty' => true)
  end

  it 'addresses remote settings messages to that corpora’s ChiefSapi without changing selection' do
    result = probe('edit')
    expect(result['message']).to include('New name: Studio', 'Device name: Mac mini', 'Scope of operations: Studio tasks')
    expect(result['target']).to end_with('/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/api/agents/chief-b/messages')
    expect(result['selected']).to eq('Home')
  end

  it 'migrates existing trust and retains other corpora when a connection is forgotten' do
    expect(probe('storage')).to include('before' => ['Home'], 'after' => %w[Home Studio], 'remaining' => ['Home'])
  end
end
