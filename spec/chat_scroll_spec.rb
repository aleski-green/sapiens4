require_relative 'support/desktop'

RSpec.describe 'Reading and composing while work arrives', :desktop do
  it 'restores draft keyboard focus when returning from another Windows window' do
    skip 'Windows activation contract' unless Gem.win_platform?
    @host = desktop_host
    start_desktop
    desktop.fill('Message ChiefSapi', 'My next thought')
    other = desktop_host
    desktop.control('type', '--text', ' continues')
    expect(desktop.value('Message ChiefSapi', 'My next thought continues')).to eq('My next thought continues')
    desktop.reload
    expect(desktop.value('Message ChiefSapi', 'My next thought continues')).to eq('My next thought continues')
  ensure
    other&.close
  end

  it 'keeps a draft and its keyboard focus while a new reply arrives' do
    @host = desktop_host
    host.configure(block: true)
    start_desktop
    desktop.fill('Message ChiefSapi', 'Please investigate')
    desktop.press('Send message')
    desktop.find('Please investigate', role: 'AXStaticText')
    desktop.fill('Message ChiefSapi', 'My next thought')
    host.release
    desktop.see('Contract test reply')
    expect(desktop.label(desktop.control('focused'))).to include('Message ChiefSapi')
    desktop.control('type', '--text', ' continues')
    expect(desktop.value('Message ChiefSapi', 'My next thought continues')).to eq('My next thought continues')
    desktop.reload
    desktop.see('Contract test reply')
    expect(desktop.value('Message ChiefSapi', 'My next thought continues')).to eq('My next thought continues')
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
