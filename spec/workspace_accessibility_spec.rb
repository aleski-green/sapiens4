require_relative 'support/desktop'
require_relative 'support/http_peer'

RSpec.describe 'Working with browser tabs and documents', :desktop do
  before do
    @pages = HTTPPeer.new do |request|
      name = request.path.include?('second') ? 'Second' : 'First'
      playing = request.path.end_with?('/playing')
      [200, "<title>#{name} player</title><h1>#{name} player</h1><a href='/#{name.downcase}/#{playing ? 'stopped' : 'playing'}'>#{playing ? 'Pause' : 'Play'} #{name}</a><label>#{name} input<input></label>",
        {'Content-Type' => 'text/html', 'X-Frame-Options' => 'DENY', 'Content-Security-Policy' => "frame-ancestors 'none'"}]
    end
    @host = desktop_host
    host.control(chief, 'workspace_open', url: @pages.url + '/first')
    start_desktop
    desktop.see('Play First')
  end
  after { @pages&.close }

  it 'opens a site that forbids framing and follows its links' do
    desktop.click('Play First')
    expect(desktop.see('Pause First')).to include('First player')
  end

  it 'restores guest keyboard focus when returning from another Windows window' do
    skip 'Windows activation contract' unless Gem.win_platform?
    desktop.fill('First input', 'Website draft')
    other = desktop_host
    desktop.control('type', '--text', ' continues')
    expect(desktop.value('First input', 'Website draft continues')).to eq('Website draft continues')
  ensure
    other&.close
  end

  it 'lets the person add a tab, navigate, and close it to return to the previous page' do
    desktop.press('Add workspace tab')
    desktop.fill('URL or file path', @pages.url + '/second')
    desktop.press('Open address')
    desktop.see('Play Second')
    expect(desktop.text).not_to include('Play First')
    desktop.press('Close Second player')
    expect(desktop.see('Play First')).not_to include('Play Second')
  end

  it 'keeps the workspace menu usable above a guest and returns to the guest afterward' do
    desktop.fill('First input', 'A draft on the website')
    desktop.press('Workspace options')
    desktop.see('Open file…')
    expect(desktop.text).not_to include('Play First')
    desktop.press('Workspace options')
    expect(desktop.find('First input', role: 'AXTextField')['value']).to eq('A draft on the website')
    desktop.click('Play First')
    desktop.see('Pause First')
  end

  it 'opens a new address from the keyboard while the workspace menu is open' do
    desktop.click('Workspace options')
    desktop.see('Open file…')
    desktop.key(Gem.win_platform? ? 'control+l' : 'command+l')
    desktop.fill('URL or file path', @pages.url + '/second')
    desktop.press('Open address')
    expect(desktop.see('Play Second')).not_to include('Play First')
  end

  it 'preserves a bookmark after reload and opens it after closing the tab' do
    desktop.press('Bookmark First player')
    desktop.see('Unbookmark First player')
    desktop.reload
    desktop.see('Unbookmark First player')
    desktop.press('Close First player')
    desktop.press('Show workspace')
    desktop.press('Workspace options')
    desktop.press('★ First player')
    desktop.see('Play First')
    expect(desktop.see('Unbookmark First player')).to include('Play First')
  end

  it 'reads a text file literally and reloads changes from disk' do
    file = File.join(host.workspace(chief), 'research.txt')
    File.write(file, 'A literal <b>research finding</b>')
    desktop.press('Add workspace tab')
    desktop.fill('URL or file path', file)
    desktop.press('Open address')
    desktop.see('A literal <b>research finding</b>')
    File.write(file, 'Revised research finding')
    desktop.press('Workspace options')
    desktop.press('Reload')
    expect(desktop.see('Revised research finding')).not_to include('A literal <b>research finding</b>')
  end

  it 'keeps guest controls operable after resizing the desktop window' do
    @desktop.process.input.puts(JSON.generate(width: 1100, height: 740))
    desktop.click('Play First')
    expect(desktop.see('Pause First')).to include('First player')
    @desktop.process.input.puts(JSON.generate(width: 1300, height: 900, top: 44))
    desktop.click('Pause First')
    expect(desktop.see('Play First')).to include('First player')
  end
end
