require_relative 'support/desktop'
require_relative 'support/relay'

RSpec.describe 'Selecting corpora with the mouse', :desktop do
  it 'opens another local corpora and restores the original draft when returning' do
    @host = desktop_host
    host.api('POST', '/api/host/local', {name: 'Studio'}, status: 201)
    start_desktop
    desktop.fill('Message ChiefSapi', 'Local draft')
    desktop.click('Local')
    desktop.click('Studio')
    desktop.click('Close corpora menu')
    desktop.find('Studio', role: 'AXHeading')
    desktop.click('Local')
    desktop.click(host.state['corpora']['name'])
    desktop.click('Close corpora menu')
    desktop.value('Message ChiefSapi', 'Local draft')
  end

  it 'pauses and resumes execution through the status menu' do
    start_desktop
    desktop.see('Message ChiefSapi')
    desktop.click('Active')
    desktop.click('Pause')
    desktop.find('Paused', role: 'AXButton')
    expect(host.state['corpora']['status']).to eq('paused')
    desktop.click('Paused')
    desktop.click('Activate')
    desktop.find('Active', role: 'AXButton')
    expect(host.state['corpora']['status']).to eq('active')
  end

  it 'selects a saved remote corpora, returns to local and retains separate drafts after reload' do
    @host = desktop_host
    relay = Relay.new
    remote = Host.new
    metadata = remote.api('GET', '/api/corpora')
    remote.control(remote.state['main_agent_id'], 'corpora_update', name: 'Remote Studio', revision: metadata['revision'])
    invitation = remote.api('POST', '/api/remote/pair', {relay: relay.url, token: relay.token}, status: 201)['qr']
    pairing = host.api('POST', '/api/host/pair', invitation, status: 202)
    pending = Contract.wait { remote.api('GET', '/api/remote')['pending'] }
    remote.api('POST', '/api/remote/approve', {peer: pending['peer']})
    Contract.wait { host.api('GET', "/api/host/pair/#{pairing['id']}")['state'] == 'approved' }
    start_desktop
    desktop.fill('Message ChiefSapi', 'Local draft')
    desktop.click('Local')
    desktop.click('Remote Studio')
    desktop.click('Close corpora menu')
    desktop.find('Remote Studio', role: 'AXHeading')
    desktop.value('Message ChiefSapi', '')
    desktop.fill('Message ChiefSapi', 'Remote draft')
    desktop.reload
    desktop.find('Remote Studio', role: 'AXHeading')
    desktop.value('Message ChiefSapi', 'Remote draft')
    desktop.click('Remote')
    desktop.click(host.state['corpora']['name'])
    desktop.click('Close corpora menu')
    desktop.find(host.state['corpora']['name'], role: 'AXHeading')
    desktop.value('Message ChiefSapi', 'Local draft')
    expect(host.state['corpora']['status']).to eq('active')
    expect(remote.state['corpora']['status']).to eq('active')
  ensure
    remote&.close
    relay&.close
  end
end
