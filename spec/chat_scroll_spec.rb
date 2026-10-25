require_relative 'support/desktop'

RSpec.describe 'Reading and composing while work arrives', :desktop do
  it 'keeps a draft and its keyboard focus while a new reply arrives' do
    @host = desktop_host
    host.configure(block: true)
    start_desktop
    desktop.fill('Message ChiefSapi', 'Please investigate')
    desktop.press('Send message')
    desktop.see('Please investigate')
    desktop.fill('Message ChiefSapi', 'My next thought')
    host.release
    desktop.see('Contract test reply')
    desktop.control('type', '--text', ' continues')
    expect(desktop.find('Message ChiefSapi')['value']).to eq('My next thought continues')
    desktop.reload
    desktop.see('Contract test reply')
    expect(desktop.find('Message ChiefSapi')['value']).to eq('My next thought continues')
  end

  it 'keeps an earlier message in view when new work completes' do
    @host = desktop_host
    12.times { |index| host.turn(host.submit(chief, "Research item #{index}: " + 'A detailed observation. ' * 12)) }
    start_desktop
    anchor = desktop.find(/Research item 3:/, role: 'AXStaticText')
    desktop.control('scroll-to', '--path', anchor.fetch('path'))
    before = desktop.find(/Research item 3:/, role: 'AXStaticText')
    host.turn(host.submit(chief, 'A new arrival'))
    desktop.see('A new arrival')
    after = desktop.find(/Research item 3:/, role: 'AXStaticText')
    expect(after.fetch('position')['y']).to be_within(3).of(before.fetch('position')['y'])
    expect(after['value']).to include('Research item 3:')
  end
end
