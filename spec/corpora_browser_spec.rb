require_relative 'support/desktop'

RSpec.describe 'Choosing and managing corpora', :desktop do
  it 'creates a named corpora through the menu and opens its own conversation' do
    start_desktop
    desktop.press('Local')
    desktop.press('＋ Create new local corpora')
    desktop.fill('Corpora name', 'Studio')
    desktop.fill('Scope of work', 'Design research')
    desktop.press('Create')
    desktop.find('Studio', role: 'AXHeading')
    desktop.press('Paused')
    desktop.press('Activate')
    desktop.see('Active')
    desktop.fill('Message ChiefSapi', 'A message for Studio')
    desktop.press('Send message')
    desktop.see('Contract test reply')
    record = host.api('GET', '/api/host')['corpora'].find { |row| row['name'] == 'Studio' }
    expect(host.api('GET', "/api/host/corpora/#{record['id']}/api/state")['turns'].map { |turn| turn['input'] }).to eq(['A message for Studio'])
    expect(host.state['turns']).to be_empty
  end

  it 'switches between corpora without activating paused work or losing a draft' do
    @host = desktop_host
    other = host.api('POST', '/api/host/local', {name: 'Studio'}, status: 201)
    route = "/api/host/corpora/#{other['id']}"
    info = host.api('GET', route + '/api/corpora')
    host.api('PUT', route + '/api/corpora/lifecycle', action: 'pause', revision: info['revision'], operation: SecureRandom.uuid)
    start_desktop
    desktop.fill('Message ChiefSapi', 'Local draft')
    desktop.press('Local')
    desktop.press('Studio')
    desktop.press('Close corpora menu')
    desktop.find('Studio', role: 'AXHeading')
    expect(desktop.text).to include('Paused')
    desktop.press('Local')
    desktop.press(host.state['corpora']['name'])
    desktop.press('Close corpora menu')
    desktop.find(host.state['corpora']['name'], role: 'AXHeading')
    expect(desktop.find('Message ChiefSapi')['value']).to eq('Local draft')
    expect(host.api('GET', route + '/api/corpora')['status']).to eq('paused')
    expect(host.state['corpora']['status']).to eq('active')
  end

  it 'pauses and resumes execution from the status menu' do
    start_desktop
    desktop.press('Active')
    desktop.press('Pause')
    desktop.see('Paused')
    expect(host.state['corpora']['status']).to eq('paused')
    desktop.press('Paused')
    desktop.press('Activate')
    desktop.see('Active')
    expect(host.state['corpora']['status']).to eq('active')
  end
end
