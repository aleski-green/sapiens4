require_relative 'support/http_peer'

RSpec.describe 'Browser and native platform probes' do
  Dir[File.join(Contract::ROOT, 'tests', '*.test.cjs')].sort.each do |file|
    it "passes the #{File.basename(file, '.test.cjs')} browser contract", :browser do
      out, error, code = Contract.capture('node', file, timeout: 90)
      expect(code).to eq(0), out + error
    end
  end

  %w[NavigationPolicy ServerReadiness DesktopUpdate].each do |name|
    it "passes the native #{name} probe", :macos do
      skip 'macOS native integration' unless RUBY_PLATFORM.include?('darwin')
      Dir.mktmpdir('sapiens native ') do |folder|
        binary = File.join(folder, name)
        out, error, code = Contract.capture('xcrun', 'swiftc', "macos/#{name}.swift", "macos/#{name}Tests.swift", '-o', binary, timeout: 90)
        expect(code).to eq(0), out + error
        out, error, code = Contract.capture(binary)
        expect(code).to eq(0), out + error
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
      'macos/Browser.swift', 'macos/BrowserTests.swift', '-o', binary, timeout: 90)
    expect(code).to eq(0), out + error
    out, error, code = Contract.capture(binary, host.url, pages.url, timeout: 120)
    expect(code).to eq(0), out + error
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
      out, error, code = Contract.capture(File.join(package, 'Sapiens4.exe'), '--self-test', result, timeout: 90)
      expect(code).to eq(0), out + error
      expect(JSON.parse(File.read(result))['ok']).to eq(true)
    end
  end
end
