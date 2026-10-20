RSpec.describe 'Remote Control Relay Servers browser flow', :host do
  def probe(scenario)
    out, error, code = Contract.capture('node', 'spec/support/relay-servers-browser.cjs', host.url, scenario)
    expect(code).to eq(0), out + error
    JSON.parse(out)
  end

  it 'adds, imports, edits, archives and restores JSON, then confirms switching and active credential changes' do
    result = probe('manage')
    expect(result).to include('heading' => 'Remote Control Relay Servers', 'archivedDefault' => false,
      'scrolling' => true, 'invalidWrites' => 0, 'hidden' => 2, 'cancelled' => 'Sapiens4 beta',
      'selected' => 'Office renamed', 'editWarning' => 'Change connection?', 'keptDraft' => true,
      'resetWrites' => %w[switch save], 'bodyHasToken' => false, 'focus' => 'Cancel')
    expect(result['initial']).to eq([{'name' => 'Sapiens4 beta', 'current' => true, 'disabled' => false},
      {'name' => 'Utana beta', 'current' => false, 'disabled' => true}])
    expect(result['saved'].find { |row| row['current'] }['name']).to eq('Sapiens4 beta')
    expect(result['archived']).to include('disabled' => true)
    expect(result['invalid']).to include('valid relay connection JSON')
    expect(result['prefill']).to include('name' => 'Office', 'connection' => {
      'format' => 'sapiens-relay-connection-v1', 'relay' => 'http://127.0.0.1:4180', 'token' => 't' * 32})
    expect(result['warning']).to include('all paired devices and remote corpora connections', 'for this local app', 'Pair all devices and reconnect all remote corpora again')
    expect(result['guide']).to start_with('https://github.com/aleski-green/sapiens4/')
  end

  it 'requires explicit beta acceptance before showing the pairing action' do
    result = probe('terms')
    expect(result).to include('gated' => true, 'acceptEnabled' => true, 'accepted' => true)
    expect(result['terms']).to include('authors, contributors, and operators disclaim liability', 'use your own securely maintained relay')
  end
end
