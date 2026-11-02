require_relative 'support/desktop'

RSpec.describe 'Linux computer settings', :desktop do
  before { skip 'Linux settings' unless Desktop.linux? }

  it 'shows native accessibility diagnostics and Linux permission guidance' do
    start_desktop
    desktop.click('Open shared computer')
    desktop.see('AT-SPI accessibility is available')
    expect(desktop.text).to include('GNOME foreground extension', 'Xorg uses native window ownership checks')
    expect(desktop.text).not_to include('macOS Accessibility', 'Windows UI Automation')
  end

  it 'identifies headless browser access without claiming desktop permission' do
    @host = Host.new(command: ['sh', File.join(Contract::ROOT, 'environments/linux/start.sh')],
      environment: {'SAPIENS_LINUX_BACKEND' => 'headless'})
    start_desktop
    desktop.click('Open shared computer')
    desktop.see('Owned browser session is connected')
    expect(desktop.text).to include('native desktop applications are unavailable')
    expect(desktop.text).not_to include('macOS Accessibility', 'AT-SPI accessibility is available')
  end
end
