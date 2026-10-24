require_relative 'support/http_peer'

RSpec.describe 'Browser and native platform probes' do
  {
    'NavigationPolicy' => [
      ['about:srcdoc', false, 'allow'], ['about:blank', false, 'allow'],
      ['https://example.com/document', false, 'allow'], ['http://example.com/document', false, 'allow'],
      ['blob:http://127.0.0.1:4174/document', false, 'allow'], ['data:text/html,hello', false, 'allow'],
      ['http://127.0.0.1:4174/workspace/', true, 'allow'], ['about:blank', true, 'allow'],
      ['https://example.com', true, 'external'], ['https://example.com', nil, 'external'],
      ['mailto:example@example.com', nil, 'external'], ['about:srcdoc', true, 'cancel'],
      ['data:text/html,hello', true, 'cancel'], ['file:///etc/passwd', false, 'cancel'],
      ['javascript:alert(1)', false, 'cancel']
    ].map { |url, frame, expected| [{url: url, mainFrame: frame}, expected] },
    'ServerReadiness' => [
      [200, 'Sapiens4 Python/3.9.6', '{"status":"ok"}', 'ready'],
      [503, 'Sapiens4', '{"status":"ok"}', 'unavailable'],
      [200, 'Other service', '{"status":"ok"}', 'unavailable'],
      [200, nil, '{"status":"ok"}', 'unavailable'],
      [200, 'Sapiens4', '{"status":"error"}', 'unavailable'],
      [200, 'Sapiens4', 'invalid JSON', 'unavailable']
    ].map { |status, server, body, expected| [{status: status, server: server, body: body}, expected] }
  }.each do |name, cases|
    it "preserves #{name} decisions at the native boundary", :macos do
      skip 'macOS native integration' unless RUBY_PLATFORM.include?('darwin')
      Dir.mktmpdir('sapiens native ') do |folder|
        binary = File.join(folder, name)
        out, error, code = Contract.capture('xcrun', 'swiftc', "macos/#{name}.swift", "macos/#{name}Probe.swift", '-o', binary, timeout: 90)
        expect(code).to eq(0), out + error
        out, error, code = Contract.capture(binary, input: JSON.generate(cases.map(&:first)))
        expect(code).to eq(0), out + error
        expect(JSON.parse(out)).to eq(cases.map(&:last))
      end
    end
  end

  it 'integrates the real host with WebKit navigation, file previews, isolation and persisted bookmarks', :macos do
    skip 'macOS WebKit integration' unless RUBY_PLATFORM.include?('darwin')
    @host = Host.new
    owner = chief
    file = File.join(host.workspace(owner), 'integration.md')
    File.write(file, 'Native browser integration')
    host.control(owner, 'workspace_open', path: file)
    pages = HTTPPeer.new do |request|
      case request.path
      when '/redirect' then [302, '', {'Location' => '/one'}]
      when '/text' then [200, 'Plain text on the web', {'Content-Type' => 'text/plain'}]
      else [200, "<title>#{request.path == '/one' ? 'First' : 'Second'} page</title><h1>Not embeddable</h1>",
        {'Content-Type' => 'text/html', 'X-Frame-Options' => 'DENY', 'Content-Security-Policy' => "frame-ancestors 'none'"}]
      end
    end
    binary = File.join(host.root, 'browser-probe')
    out, error, code = Contract.capture('xcrun', 'swiftc', '-framework', 'Cocoa', '-framework', 'WebKit',
      'macos/Browser.swift', 'macos/BrowserProbe.swift', '-o', binary, timeout: 90)
    expect(code).to eq(0), out + error
    out, error, code = Contract.capture(binary, host.url, pages.url, timeout: 120)
    expect(code).to eq(0), out + error
    observed = JSON.parse(out)
    expect(observed).to include('separateView' => true, 'zoom' => 1.5,
      'text' => "# Hello\n<script>window.bad=true</script>", 'textScript' => 'undefined', 'guestBridge' => false,
      'darkBackground' => 'rgb(0, 0, 0)', 'lightBackground' => 'rgb(255, 255, 255)',
      'reloadedText' => 'Updated on disk', 'hidden' => true, 'scriptTitle' => 'Changed title',
      'pdfError' => '', 'closedTabs' => 0, 'openedFile' => 'integration.md', 'hiddenFiles' => true,
      'frameDenyingContent' => 'Not embeddable', 'webTextBackground' => 'rgb(0, 0, 0)', 'emptyWorkspace' => 'New tab')
    expect(observed['textURL']).to eq(observed['noteURL'])
    expect(observed['pdfURL']).to eq(observed['documentURL'])
    expect(observed['pickerDirectory']).to eq(observed['workspaceDirectory'])
    expect(observed['plus']).to eq('modal' => false, 'focused' => 'browser-address', 'value' => '', 'tabs' => 2)
    expect(observed['settled']).not_to be_empty
    expect(observed['settled']).to all(eq(true))
    expect(host.control(owner, 'workspace')['tabs']).to be_empty
    expect(File.identical?(host.control(owner, 'workspace')['bookmarks'].first['path'], file)).to eq(true)
  ensure
    pages.close if pages
    @host.close if @host
  end

  it 'passes the packaged Windows desktop navigation and isolation probe', :windows do
    skip 'Windows desktop integration' unless Gem.win_platform?
    package = ENV.fetch('SAPIENS_TEST_WINDOWS_PACKAGE')
    Dir.mktmpdir('sapiens desktop ') do |folder|
      result = File.join(folder, 'navigation.json')
      input = File.join(folder, 'cases.json')
      trusted = ['http://127.0.0.1:4174/workspace/', 'http://127.0.0.1:4175/workspace/',
        'http://localhost:4174/workspace/', 'http://127.0.0.1:4174/other', 'https://example.com/workspace/',
        'file:///C:/workspace/', 'http://user@127.0.0.1:4174/workspace/']
      guests = ['https://example.com', 'http://example.com', 'file:///C:/test%20file.html', 'about:blank',
        'javascript:alert(1)', 'shell:AppsFolder', 'file://server/share/test', 'https://user:pass@example.com',
        'http://127.0.0.1:4174/workspace/', 'http://localhost:4174/workspace/', 'http://[::1]:4174/workspace/']
      File.write(input, JSON.generate(origin: 'http://127.0.0.1:4174', trusted: trusted, guest: guests))
      out, error, code = Contract.capture(File.join(package, 'Sapiens4.exe'), '--probe-navigation', input, result, timeout: 90)
      expect(code).to eq(0), out + error
      expect(JSON.parse(File.read(result))).to eq('trusted' => [true] + [false] * 6, 'guest' => [true] * 4 + [false] * 7)
    end
  end
end
