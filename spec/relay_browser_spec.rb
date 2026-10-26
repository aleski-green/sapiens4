require_relative 'support/desktop'

RSpec.describe 'Managing relay connections', :desktop do
  def catalogue; host.api('GET', '/api/host/relays'); end

  it 'keeps an invalid connection editable and saves a valid relay without switching to it' do
    start_desktop
    desktop.press('Local')
    desktop.press('Remote Control Relay Servers')
    desktop.press(/Add your own relay/)
    desktop.fill('Name', 'Office')
    desktop.fill('Connection JSON', 'not json')
    desktop.press('Save')
    desktop.see('valid relay connection JSON')
    expect(catalogue['servers'].map { |row| row['name'] }).not_to include('Office')
    desktop.fill('Connection JSON', JSON.generate(format: 'sapiens-relay-connection-v1', relay: 'https://relay.example', token: 't' * 32))
    desktop.press('Save')
    desktop.see('Office')
    expect(catalogue['selected']).to eq('sapiens-beta')
    desktop.press(/Office/, role: 'AXRadioButton')
    desktop.see('Switch server?')
    desktop.press('Cancel')
    expect(catalogue['selected']).to eq('sapiens-beta')
    desktop.press(/Office/, role: 'AXRadioButton')
    desktop.press('Switch & revoke all')
    selected = Contract.wait do
      state = catalogue
      state if state['servers'].find { |row| row['id'] == state['selected'] }['name'] == 'Office'
    end
    expect(selected['selected']).not_to eq('sapiens-beta')
  end
end
