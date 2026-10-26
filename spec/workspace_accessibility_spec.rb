require_relative 'support/host'

RSpec.describe 'Native workspace accessibility' do
  before(:all) do
    skip 'Requires macOS or Windows and SAPIENS_TEST_BLINDLY4 with accessibility access' unless
      (RUBY_PLATFORM.include?('darwin') || Gem.win_platform?) && ENV['SAPIENS_TEST_BLINDLY4']
    @build = Dir.mktmpdir('sapiens accessibility ')
    if Gem.win_platform?
      @binary = File.join(@build, 'Probe.exe')
      out, error, code = Contract.capture('dotnet', 'build', 'spec/support/windows_accessibility/Probe.csproj',
        '-o', @build, timeout: 90)
    else
      @binary = File.join(@build, 'browser-probe')
      out, error, code = Contract.capture('xcrun', 'swiftc', '-framework', 'Cocoa', '-framework', 'WebKit',
        'macos/Browser.swift', 'macos/BrowserTests.swift', '-o', @binary, timeout: 90)
    end
    raise out + error unless code == 0
  end

  after(:all) { FileUtils.remove_entry(@build) if @build }

  before do
    @host = Gem.win_platform? ? Host.new(command: [@binary, '--runtime-dir', Contract::ROOT]) : Host.new
    @owner = chief
    @tab = open_player('First')
    @app = Gem.win_platform? ? host.process : Contract::Child.new(@binary, '--accessibility', host.url)
    if Gem.win_platform?
      expect(@app.stdout.lines.map(&:strip)).to include('TITLE: Sapiens4')
    else
      Contract.wait(description: 'native fixture startup') { @app.stdout.include?('READY') }
    end
    control('activate')
    find_control('Play First')
  end

  after do
    @app&.close unless Gem.win_platform?
    @host&.close
  end

  def control(command, *args)
    out, error, code = Contract.wait(description: "stable accessibility #{command}") do
      result = Contract.capture(ENV.fetch('SAPIENS_TEST_BLINDLY4'), command, '--pid', @app.pid.to_s, *args)
      # UIA elements can disappear while a WebView loads/closes. Retry reads only.
      result unless Gem.win_platform? && %w[tree focused].include?(command) &&
        result[2] != 0 && result[0].match?(/0x80040201|0x00000000/)
    end
    expect(code).to eq(0), out + error
    JSON.parse(out)
  end

  def tree
    result = control('tree', '--depth', '40', '--max-nodes', '10000')
    expect(result['truncated']).to eq(false)
    flatten = lambda do |node, path|
      [node.merge('path' => path)] + node.fetch('children', []).each_with_index.flat_map do |child, i|
        flatten.call(child, path.empty? ? i.to_s : "#{path}.#{i}")
      end
    end
    flatten.call(result.fetch('tree'), '')
  end

  def find_control(title)
    Contract.wait(description: "accessible #{title}") { tree.find { |n| n['title'] == title } }
  end

  def web_area_role; Gem.win_platform? ? 'AXTextArea' : 'AXWebArea'; end

  def press(title)
    node = find_control(title)
    if Gem.win_platform? && title == 'Workspace options'
      # Chromium exposes this expandable button without UIA InvokePattern.
      control('click', '--x', (node['position']['x'] + node['size']['width'] / 2).to_i.to_s,
        '--y', (node['position']['y'] + node['size']['height'] / 2).to_i.to_s)
    else
      control('press', '--path', node.fetch('path'))
    end
  end

  def open_player(name)
    path = File.join(host.workspace(@owner), "#{name}.html")
    File.write(path, <<~HTML)
      <title>#{name} player</title><body style="margin:0">
      <button onclick="this.textContent='Pause #{name}'">Play #{name}</button>
      <input aria-label="#{name} input">
    HTML
    host.control(@owner, 'workspace_open', path: path)['workspace']['active_tab']
  end

  it 'exposes the guest player alongside the shell and performs its accessible Play action' do
    expect(tree.count { |n| n['role'] == web_area_role }).to eq(2)
    press('Play First')
    expect(find_control('Pause First')['role']).to eq('AXButton')
  end

  it 'exposes only the selected guest and returns keyboard focus when that guest closes' do
    second = open_player('Second')
    find_control('Play Second')
    expect(tree.map { |n| n['title'] }).not_to include('Play First')
    host.control(@owner, 'workspace_focus', id: @tab)
    find_control('Play First')
    expect(tree.map { |n| n['title'] }).not_to include('Play Second')
    input = find_control('First input')
    control('focus', '--path', input.fetch('path'))
    expect(control('focused')['title']).to eq('First input')
    host.control(@owner, 'workspace_close', id: @tab)
    find_control('Play Second')
    expect(control('focused')['title']).not_to eq('First input')
    expect(tree.map { |n| n['title'] }).not_to include('Play First')
    host.control(@owner, 'workspace_close', id: second)
    Contract.wait { tree.count { |n| n['role'] == web_area_role } == 1 }
  end

  it 'keeps the guest aligned after resizing with a shell inset and hides it behind workspace menus' do
    before = find_control('Play First')
    @app.input.puts(JSON.generate(width: 1300, height: 900))
    after = Contract.wait do
      node = find_control('Play First')
      node if node['position'] != before['position']
    end
    @app.input.puts(JSON.generate(width: 1300, height: 900, top: 44))
    inset = Contract.wait do
      node = find_control('Play First')
      node if node['position'] != after['position']
    end
    expect(inset['position']['x']).to be_within(1).of(after['position']['x'])
    expect(inset['position']['y']).to be_within(1).of(after['position']['y'] + 44)
    input = find_control('First input')
    control('focus', '--path', input.fetch('path'))
    press('Workspace options')
    Contract.wait { tree.none? { |n| n['title'] == 'Play First' } }
    expect(control('focused')['title']).not_to eq('First input')
    press('Workspace options')
    find_control('Play First')
    press('Play First')
    expect(find_control('Pause First')['role']).to eq('AXButton')
  end
end
