require_relative 'support/http_peer'

RSpec.shared_examples 'Linux headless command translation' do
  before do
    skip 'Headless browser qualification required' unless ENV['SAPIENS_TEST_HEADLESS_BROWSERS'] == '1'
    @directory = Dir.mktmpdir('sapiens-bridge-')
    @environment = {'SAPIENS_LINUX_BACKEND' => 'headless', 'SAPIENS_LINUX_BROWSER_SOCKET' => File.join(@directory, 'browser.sock'),
      'PLAYWRIGHT_BROWSERS_PATH' => File.join(Contract::ROOT, 'submodules/libs4/.cache/playwright')}
    @environment['DBUS_SESSION_BUS_ADDRESS'] = nil if RSpec.current_example.metadata[:no_bus]
    @server = Contract::Child.new('sh', File.join(Contract::ROOT, 'environments/linux/headless.sh'), 'serve', env: @environment)
    Contract.wait(description: 'Linux browser bridge readiness') { @server.stdout.include?('READY') }
    @pages = HTTPPeer.new do |_request|
      [200, '<title>Bridge fixture</title><form action="/submitted"><label>Draft<input name="draft"></label>' \
        '<label>Secret<input type="password" value="fixture-secret"></label><button>Send fixture</button></form>',
        {'Content-Type' => 'text/html; charset=utf-8', 'Cache-Control' => 'no-store'}]
    end
  end

  after do
    @server&.signal('TERM')
    @server&.close
    @pages&.close
    FileUtils.remove_entry(@directory) if @directory
  end

  def capture(*args)
    Contract.capture(Contract::BINARY, 'computer', *args, chdir: @directory, env: @environment)
  end

  def command(*args)
    output, error, status = capture(*args)
    expect(status).to eq(0), output + error
    JSON.parse(output)
  end

  def open_page
    @pid = command('launch', browser).fetch('pid').to_s
    command('blindly', 'open', '--url', @pages.url)
    command('read', '--pid', @pid).fetch('nodes')
  end

  it 'translates discovery, Unicode editing and exact-draft submission without native accessibility' do
    rows = open_page
    expect(command('blindly', 'apps').fetch('apps')).to include(a_hash_including('pid' => @pid.to_i))
    expect(JSON.generate(rows)).not_to include('fixture-secret')
    expect(rows).to include(a_hash_including('role' => 'AXSecureTextField'))
    draft = rows.find { |row| row['title'] == 'Draft' }.fetch('path')
    button = command('blindly', 'find', '--pid', @pid, '--title', 'Send fixture').fetch('matches').first.fetch('path')
    text = 'Café العربية 🐧'
    expect(command('blindly', 'paste', '--pid', @pid, '--target-path', draft, '--text', text)['verified']).to eq(true)
    args = ['blindly', 'press', '--pid', @pid, '--path', button, '--require-value-path', draft, '--require-value']
    expect(capture(*args, 'Wrong draft').last).to eq(77)
    expect(@pages.requests).not_to include(a_hash_including(path: a_string_starting_with('/submitted')))
    command(*args, text)
    expect(@pages.requests.count { |r| URI.decode_www_form(URI.parse(r[:path]).query.to_s).include?(['draft', text]) }).to eq(1)
  end

  it 'does not autolaunch desktop services when no session bus is available', :no_bus do
    command('launch', browser)
    services = Dir.glob('/proc/[0-9]*/environ').filter_map do |path|
      name = File.read(File.join(File.dirname(path), 'comm')).strip
      next unless name == 'dbus-daemon' || name.start_with?('xdg-desktop-por')
      environment = File.binread(path).split("\0").select { |entry| entry.include?('=') }.to_h { |entry| entry.split('=', 2) }
      next unless environment['SAPIENS_LINUX_BROWSER_SOCKET'] == @environment['SAPIENS_LINUX_BROWSER_SOCKET']
      File.basename(File.dirname(path)).to_i
    rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
      nil
    end
    expect(services).to be_empty
  ensure
    services&.each { |pid| Process.kill('TERM', pid) rescue Errno::ESRCH }
  end

  it 'cancels a pending click when its requester disconnects and invalidates the old session' do
    @pages.handler = lambda do |request|
      body = if request.path == '/scrolled'
        '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'
      else
        '<title>Pending click</title><form action="/submitted" style="margin-top:10000px">' \
          '<button>Send fixture</button><img loading="lazy" src="/scrolled" width="1" height="1"></form>' \
          '<div style="position:fixed;inset:0;background:white"></div>'
      end
      [200, body, {'Content-Type' => request.path == '/scrolled' ? 'image/svg+xml' : 'text/html'}]
    end
    button = open_page.find { |row| row['title'] == 'Send fixture' }.fetch('path')
    snapshot = command('read', '--pid', @pid).fetch('snapshot')
    client = UNIXSocket.new(@environment.fetch('SAPIENS_LINUX_BROWSER_SOCKET'))
    client.puts(JSON.generate(['press', '--path', button]))
    Contract.wait(description: 'pending click scrolled its target into view') do
      @pages.requests.any? { |request| request[:path] == '/scrolled' }
    end
    client.close
    expect(command('blindly', 'apps').fetch('apps')).to be_empty
    expect(@pages.requests).not_to include(a_hash_including(path: a_string_starting_with('/submitted')))
    open_page
    expect(capture('blindly', 'press', '--path', button).last).to eq(77)
    expect(capture('read', '--snapshot', snapshot).last).to eq(77)
  ensure
    client&.close unless client&.closed?
  end

  it 'refuses stale paths, foreign session identities, secret edits and unguarded Enter' do
    rows = open_page
    draft = rows.find { |row| row['title'] == 'Draft' }.fetch('path')
    secret = rows.find { |row| row['role'] == 'AXSecureTextField' }.fetch('path')
    expect(capture('blindly', 'paste', '--pid', '2147483647', '--target-path', draft, '--text', 'wrong process').last).to eq(77)
    expect(capture('blindly', 'set-value', '--pid', @pid, '--path', secret, '--value', 'changed').last).to eq(77)
    expect(capture('blindly', 'key', '--pid', @pid, '--key', 'enter').last).to eq(64)
    command('blindly', 'open', '--url', @pages.url + '/other')
    expect(capture('blindly', 'paste', '--pid', @pid, '--target-path', draft, '--text', 'stale').last).to eq(77)
    expect(@pages.requests).not_to include(a_hash_including(path: a_string_starting_with('/submitted')))
  end

  it 'rejects unsupported commands and navigation schemes without external effects' do
    open_page
    expect(capture('blindly', 'evaluate', '--script', '1+1').last).to eq(64)
    expect(capture('launch', 'constructor').last).to eq(64)
    expect(capture('blindly', 'open', '--url', 'file:///etc/passwd').last).to eq(64)
    expect(capture('blindly', 'open', '--url', @pages.url, '--unknown', 'value').last).to eq(64)
    expect(command('read', '--pid', @pid).fetch('nodes').first['title']).to eq('Bridge fixture')
  end

  it 'keeps observations bounded and paginates without losing retained targets' do
    @pages.close
    @pages = HTTPPeer.new do |_request|
      [200, '<title>Many controls</title>' + (1..50).map { |i| "<label>Draft #{i}<textarea>#{'é' * 1500}</textarea></label>" }.join,
        {'Content-Type' => 'text/html; charset=utf-8'}]
    end
    open_page
    snapshot = command('read', '--pid', @pid)
    rows = snapshot.fetch('nodes')
    while snapshot['next_offset']
      expect(JSON.generate(snapshot).bytesize).to be < 48000
      snapshot = command('read', '--snapshot', snapshot.fetch('snapshot'), '--offset', snapshot.fetch('next_offset').to_s)
      rows.concat(snapshot.fetch('nodes'))
    end
    expect(rows.map { |row| row.fetch('path') }.uniq.size).to eq(51)
    expect(rows.last['title']).to eq('Draft 50')
    matches = command('blindly', 'find', '--pid', @pid, '--title', 'dRaFt', '--role', 'aXtExTaReA', '--limit', '2')
    expect(matches.fetch('matches').map { |row| row.fetch('title') }).to eq(['Draft 1', 'Draft 2'])
    expect(matches.fetch('truncated')).to eq(true)
    exact = command('blindly', 'find', '--pid', @pid, '--title', 'DRAFT 50', '--limit', '1')
    expect(exact.fetch('matches').map { |row| row.fetch('title') }).to eq(['Draft 50'])
    expect(exact.fetch('truncated')).to eq(false)
    expect(command('blindly', 'paste', '--pid', @pid, '--target-path', rows[1].fetch('path'), '--text', 'updated')['verified']).to eq(true)
  end

  it 'retains host computer ownership checks before dispatching browser actions' do
    fixture = Host.new(environment: @environment)
    owner = fixture.state.fetch('main_agent_id')
    other = fixture.agent('OtherOwner')
    fixture.configure(block: true)
    fixture.submit(owner, 'Hold the first turn')
    fixture.submit(other, 'Hold the second turn')
    calls = Contract.wait(description: 'both blocked provider calls') { fixture.calls if fixture.calls.size == 2 }
    run = lambda do |actor, *args|
      call = calls.find { |entry| entry['owner'] == actor }
      Contract.capture(Contract::BINARY, 'computer', *args, chdir: fixture.workspace(actor),
        env: fixture.environment.merge('SAPIENS_AGENCY_RUN' => call.fetch('agency_run')))
    end
    output, error, status = run.call(owner, 'launch', browser)
    expect(status).to eq(0), output + error
    output, error, status = run.call(other, 'blindly', 'open', '--url', @pages.url)
    expect(status).not_to eq(0), output + error
    expect(@pages.requests).to be_empty
    expect(fixture.state.fetch('computer').fetch('owner')).to eq(owner)
  ensure
    fixture&.close
  end

  it 'edits standard contenteditable controls and reports the observed page URL' do
    @pages.close
    @pages = HTTPPeer.new do |_request|
      [200, '<title>Editable fixture</title><div contenteditable role="textbox" aria-label="Rich draft"></div>',
        {'Content-Type' => 'text/html; charset=utf-8'}]
    end
    rows = open_page
    draft = rows.find { |row| row['title'] == 'Rich draft' }
    expect(draft).not_to be_nil
    expect(command('blindly', 'paste', '--pid', @pid, '--target-path', draft.fetch('path'), '--text', 'Café 🐧')['verified']).to eq(true)
    expect(command('read', '--pid', @pid).fetch('url')).to eq(@pages.url + '/')
  end

  it 'selects a Unicode option and refuses unavailable choices without changing the selection' do
    @pages.close
    @pages = HTTPPeer.new do |_request|
      [200, '<title>Select fixture</title><label>Language<select><option value="en">English</option>' \
        '<option value="日本語">日本語</option><option disabled value="blocked">Unavailable</option></select></label>',
        {'Content-Type' => 'text/html; charset=utf-8'}]
    end
    select = open_page.find { |row| row['role'] == 'AXComboBox' }
    choice = select.fetch('options').find { |option| option['label'] == '日本語' }
    expect(choice).to include('value' => '日本語', 'enabled' => true)
    expect(select.fetch('options')).to include(hash_including('value' => 'blocked', 'enabled' => false))
    expect(select.fetch('options_truncated')).to eq(false)
    control = select.fetch('path')
    expect(command('blindly', 'select', '--pid', @pid, '--path', control, '--value', choice.fetch('value'))).to include('ok' => true, 'value' => '日本語')
    %w[missing blocked].each do |value|
      expect(capture('blindly', 'select', '--pid', @pid, '--path', control, '--value', value).last).to eq(64)
      expect(command('blindly', 'inspect', '--pid', @pid, '--path', control).fetch('value')).to eq('日本語')
    end
  end
end

RSpec.describe 'Linux headless bridge' do
  %w[Browser Firefox].each do |name|
    context name do
      let(:browser) { name }
      include_examples 'Linux headless command translation'
    end
  end
end
