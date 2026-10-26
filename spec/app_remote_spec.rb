require_relative 'support/desktop'
require_relative 'support/relay'

RSpec.describe 'Connecting from the shipped remote app', :desktop do
  before do
    skip 'Remote WebKit fixture currently runs on macOS' if Gem.win_platform?
    @relay = Relay.new
    @host = Host.new
    @invitation = host.api('POST', '/api/remote/pair', {relay: @relay.url, token: @relay.token}, status: 201)['qr']
    start_desktop(@relay.url + '/mac')
  end
  after { @relay&.close }

  def connect
    desktop.press('Connect remote corpora')
    desktop.fill('Or paste an invitation', JSON.generate(@invitation))
    desktop.press('Connect')
    pending = Contract.wait { host.api('GET', '/api/remote')['pending'] }
    expect(desktop.see(pending['confirmation_code'])).to include('Approve this matching code')
    expect(host.state['turns']).to be_empty
    host.api('POST', '/api/remote/approve', {peer: pending['peer']})
    desktop.see('Message ChiefSapi')
  end

  it 'waits for matching-code approval, sends an encrypted message and reconnects after reload' do
    connect
    desktop.fill('Message ChiefSapi', 'A private remote message')
    desktop.press('Send message')
    desktop.see('Contract test reply')
    desktop.fill('Message ChiefSapi', 'Unsent remote draft')
    desktop.reload
    desktop.see('Contract test reply')
    expect(desktop.find('Message ChiefSapi')['value']).to eq('Unsent remote draft')
    expect(host.state['turns'].map { |turn| turn['input'] }).to eq(['A private remote message'])
  end

  it 'rejects a malformed invitation and still accepts a valid invitation afterward' do
    desktop.press('Connect remote corpora')
    desktop.fill('Or paste an invitation', 's4.A.abc.abc.abc.A.1')
    desktop.press('Connect')
    desktop.see('Use the QR')
    expect(host.api('GET', '/api/remote')['pending']).to be_nil
    desktop.fill('Or paste an invitation', JSON.generate(@invitation))
    desktop.press('Connect')
    pending = Contract.wait { host.api('GET', '/api/remote')['pending'] }
    expect(desktop.see(pending['confirmation_code'])).to include('Approve this matching code')
  end
end
