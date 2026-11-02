require_relative 'support/linux_input'

RSpec.describe 'Linux native automation' do
  include LinuxInput
  before do
    skip 'Isolated Linux automation session required' unless ENV['SAPIENS_TEST_LINUX_AUTOMATION'] == '1'
    overview(false) if ENV['SAPIENS_TEST_OVERVIEW'] == '1'
    @binary = File.join(Contract::ROOT, 'submodules/blindly4/.build/debug/blindly4')
    executable = File.join(Contract::ROOT, '.build/linux-controls')
    flags, error, status = Contract.capture('pkg-config', '--cflags', '--libs', 'gtk4', 'x11')
    expect(status).to eq(0), error
    _, error, status = Contract.capture('cc', '-Wall', '-Wextra', '-Werror',
      File.join(Contract::ROOT, 'spec/support/LinuxControls.c'), '-o', executable, *flags.split)
    expect(status).to eq(0), error
    @window = Contract::Child.new(executable)
    Contract.wait(description: 'native control discovery') do
      output, _, status = Contract.capture(@binary, 'find', '--pid', @window.pid.to_s, '--title', 'Draft', '--role', 'TextField')
      @draft = status == 0 && JSON.parse(output).fetch('matches').find { |node| node['role'] == 'AXTextField' }
    end
  end

  after do
    overview(false) if ENV['SAPIENS_TEST_OVERVIEW'] == '1'
    @input&.signal('TERM')
    @input&.close
    if @window
      @window.signal('TERM')
      @window.close
    end
  end

  def cli(*arguments)
    output, error, status = Contract.capture(@binary, *arguments)
    expect(status).to eq(0), output + error
    JSON.parse(output)
  end

  it 'blocks keyboard input while the Shell overview covers the application' do
    skip 'Isolated overview session required' unless ENV['SAPIENS_TEST_OVERVIEW'] == '1'
    consent_input(binary: @binary, pid: @window.pid)
    cli('set-value', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'), '--value', 'Before overlay')
    overview(true)
    Contract.wait(description: 'overview blocks foreground verification') do
      output, _, status = Contract.capture('gdbus', 'call', '--session', '--dest', 'org.gnome.Shell',
        '--object-path', '/org/sapiens/Blindly/Foreground', '--method', 'org.sapiens.Blindly.Foreground1.Get')
      status == 0 && output == "(uint32 0,)\n"
    end
    output, error, status = Contract.capture(@binary, 'key', '--pid', @window.pid.to_s, '--key', 'a')
    expect(status).to eq(77), output + error
    expect(cli('inspect', '--pid', @window.pid.to_s, '--path', @draft.fetch('path')).fetch('value')).to eq('Before overlay')
    expect(@window.stdout).not_to include('SENT ')
  end

  it 'discovers real controls, preserves Unicode edits and redacts passwords' do
    expect(cli('apps').fetch('apps')).to include(a_hash_including('pid' => @window.pid))
    cli('set-value', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'), '--value', "Ubuntu café العربية")
    expect(cli('inspect', '--pid', @window.pid.to_s, '--path', @draft.fetch('path')).fetch('value')).to eq("Ubuntu café العربية")
    tree = cli('tree', '--pid', @window.pid.to_s, '--depth', '8', '--max-nodes', '100')
    expect(JSON.generate(tree)).not_to include('fixture-secret')
    expect(JSON.generate(tree)).to include('AXSecureTextField')
  end

  it 'rejects a mismatched draft and permits an exact targeted action' do
    cli('set-value', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'), '--value', 'Review this fixture')
    button = cli('find', '--pid', @window.pid.to_s, '--title', 'Send', '--role', 'Button').fetch('matches').first
    arguments = ['press', '--pid', @window.pid.to_s, '--path', button.fetch('path'),
      '--require-value-path', @draft.fetch('path'), '--require-value']
    output, _, status = Contract.capture(@binary, *arguments, 'Different text')
    expect(status).to eq(77), output
    expect(@window.stdout).not_to include('SENT ')
    cli(*arguments, 'Review this fixture')
    Contract.wait(description: 'native button effect') { @window.stdout.include?('SENT ') }
    expect(@window.stdout.lines.find { |line| line.start_with?('SENT ') }.split.last.unpack1('m0')).to eq('Review this fixture')
  end

  it 'bounds accessibility traversal without changing the draft' do
    tree = cli('tree', '--pid', @window.pid.to_s, '--depth', '8', '--max-nodes', '1')
    expect(tree.fetch('truncated')).to eq(true)
    expect(cli('inspect', '--pid', @window.pid.to_s, '--path', @draft.fetch('path')).fetch('value')).to eq('')
  end

  it 'reports the current control after focus moves within the application' do
    consent_input(binary: @binary, pid: @window.pid) if ENV['SAPIENS_TEST_HEADLESS'] == '1'
    cli('activate', '--pid', @window.pid.to_s)
    [['focus-send', 'AXButton'], ['focus', 'AXTextField'], ['focus-send', 'AXButton']].each do |command, role|
      @window.input.puts(command)
      focused = nil
      Contract.wait(description: "focus moved to #{role}") do
        focused = cli('focused', '--pid', @window.pid.to_s)
        focused['role'] == role
      end
      expect(focused).to include('pid' => @window.pid, 'focused' => true)
    end
    expect(@window.stdout).not_to include('SENT ')
  end

  it 'does not advertise unsupported global coordinates on Wayland' do
    skip 'Wayland only' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
    expect(cli('inspect', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'))).not_to have_key('position')
  end

  it 'uses the requested display scale for native controls' do
    skip 'Explicit scaling run required' unless ENV['SAPIENS_TEST_SCALE']
    @window.input.puts('scale')
    Contract.wait(description: 'native scale observation') { @window.stdout.include?('SCALE ') }
    expect(@window.stdout[/SCALE (\d+)/, 1].to_i).to eq(Integer(ENV.fetch('SAPIENS_TEST_SCALE')))
  end

  {
    'click' => %w[--x 0 --y 0],
    'scroll' => %w[--direction down --amount 1]
  }.each do |operation, arguments|
    it "rejects Wayland #{operation} without pointer consent or fixture changes" do
      skip 'Wayland only' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
      output, error, status = Contract.capture(@binary, operation, '--pid', @window.pid.to_s, *arguments)
      expect(status).to eq(77), output + error
      expect(@window.stdout).not_to match(/SENT |SCROLLED /)
    end
  end

  it 'replaces and verifies a Unicode draft through the native editable control' do
    consent_input(binary: @binary, pid: @window.pid) if ENV['SAPIENS_TEST_HEADLESS'] == '1'
    cli('set-value', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'), '--value', 'Previous draft')
    result = cli('paste', '--pid', @window.pid.to_s, '--target-path', @draft.fetch('path'), '--text', 'Café العربية 🐧')
    expect(result.fetch('verified')).to eq(true)
    expect(cli('inspect', '--pid', @window.pid.to_s, '--path', @draft.fetch('path')).fetch('value')).to eq('Café العربية 🐧')
    expect(@window.stdout).not_to include('SENT ')
  end

  it 'refuses keyboard input without a consented session on Wayland' do
    skip 'Wayland only' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
    output, error, status = Contract.capture(@binary, 'key', '--pid', @window.pid.to_s, '--key', 'a')
    expect(status).to eq(77), output + error
    expect(cli('inspect', '--pid', @window.pid.to_s, '--path', @draft.fetch('path')).fetch('value')).to eq('')
  end

  it 'injects an Xorg key with a verified foreground PID and exact draft' do
    skip 'Xorg only' unless ENV['XDG_SESSION_TYPE'] == 'x11'
    cli('set-value', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'), '--value', 'Xorg input')
    arguments = ['key', '--pid', @window.pid.to_s, '--key', 'enter', '--target-path', @draft.fetch('path'), '--require-value']
    _, _, status = Contract.capture(@binary, *arguments, 'wrong')
    expect(status).to eq(77)
    expect(@window.stdout).not_to include('SENT ')
    cli(*arguments, 'Xorg input')
    Contract.wait(description: 'XTest keyboard effect') { @window.stdout.include?('SENT ') }
    expect(@window.stdout.lines.grep(/^SENT /).length).to eq(1)
  end

  it 'checks Xorg pointer ownership before clicking and scrolling' do
    skip 'Xorg only' unless ENV['XDG_SESSION_TYPE'] == 'x11'
    _, _, status = Contract.capture(@binary, 'click', '--pid', @window.pid.to_s, '--x', '0', '--y', '0')
    expect(status).to eq(77)
    expect(@window.stdout).not_to include('SENT ')
    @window.input.puts('point')
    point = nil
    Contract.wait(description: 'fixture screen coordinates') { point = @window.stdout.match(/BUTTON (\d+) (\d+)/) }
    cli('click', '--pid', @window.pid.to_s, '--x', point[1], '--y', point[2])
    Contract.wait(description: 'XTest button effect') { @window.stdout.include?('SENT ') }
    cli('scroll', '--pid', @window.pid.to_s, '--direction', 'down', '--amount', '1')
    Contract.wait(description: 'XTest scroll effect') { @window.stdout.include?('SCROLLED ') }
  end

  it 'clicks and scrolls only inside the verified Wayland foreground window with pointer consent' do
    skip 'Wayland only' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
    skip 'Native Wayland backend required for scroll forwarding' if ENV['SAPIENS_TEST_NESTED'] == '1'
    consent_input(binary: @binary, pid: @window.pid, pointer: true)
    @window.input.puts('fullscreen')
    point = nil
    Contract.wait(description: 'fullscreen fixture coordinates') do
      @window.input.puts('point')
      point = @window.stdout.scan(/BUTTON (\d+) (\d+) FULLSCREEN/).last
    end
    output, error, status = Contract.capture(@binary, 'click', '--pid', @window.pid.to_s, '--x', '-1', '--y', '-1')
    expect(status).to eq(77), output + error
    expect(@window.stdout).not_to include('SENT ')
    cli('click', '--pid', @window.pid.to_s, '--x', point[0], '--y', point[1])
    Contract.wait(description: 'Wayland pointer button effect') { @window.stdout.include?('SENT ') }
    cli('scroll', '--pid', @window.pid.to_s, '--direction', 'down', '--amount', '1')
    Contract.wait(description: 'Wayland pointer scroll effect') { @window.stdout.include?('SCROLLED ') }
    set_verifier(false)
    _, _, status = Contract.capture(@binary, 'click', '--pid', @window.pid.to_s, '--x', point[0], '--y', point[1])
    expect(status).to eq(77)
    expect(@window.stdout.lines.grep(/^SENT /).length).to eq(1)
  rescue RSpec::Expectations::ExpectationNotMetError, StandardError
    warn "Fixture: #{@window.stdout}\n#{@window.stderr}\nInput: #{@input&.stderr}" if @window
    raise
  ensure
    set_verifier(true) if @input
  end

  it 'injects a guarded key only while portal consent and foreground verification remain available' do
    skip 'Wayland only' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
    consent_input(binary: @binary, pid: @window.pid)
    cli('activate', '--pid', @window.pid.to_s)
    output, error, status = Contract.capture('gdbus', 'call', '--session', '--dest', 'org.sapiens.Blindly.Input',
      '--object-path', '/org/sapiens/Blindly/Input', '--method', 'org.sapiens.Blindly.Input1.Click', @window.pid.to_s, '0', '0')
    expect(status).not_to eq(0)
    expect(output + error).to include('Pointer consent is required')
    _, _, status = Contract.capture('gdbus', 'call', '--session', '--dest', 'org.sapiens.Blindly.Input',
      '--object-path', '/org/sapiens/Blindly/Input', '--method', 'org.sapiens.Blindly.Input1.Key', '2147483647', '97', '[]')
    expect(status).not_to eq(0)
    expect(cli('inspect', '--pid', @window.pid.to_s, '--path', @draft.fetch('path')).fetch('value')).to eq('')
    cli('set-value', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'), '--value', 'Guarded input')
    cli('focus', '--pid', @window.pid.to_s, '--path', @draft.fetch('path'))
    cli('key', '--pid', @window.pid.to_s, '--key', 'enter', '--target-path', @draft.fetch('path'), '--require-value', 'Guarded input')
    Contract.wait(description: 'portal keyboard effect') { @window.stdout.include?('SENT ') }
    expect(@window.stdout.lines.grep(/^SENT /).length).to eq(1)
    set_verifier(false)
    _, _, status = Contract.capture(@binary, 'key', '--pid', @window.pid.to_s, '--key', 'enter')
    expect(status).to eq(77)
    expect(@window.stdout.lines.grep(/^SENT /).length).to eq(1)
    set_verifier(true)
    Contract.wait(description: 'foreground verifier restored') { cli('apps').fetch('apps').any? { |app| app['pid'] == @window.pid && app['frontmost'] } }
    @input.signal('TERM')
    @input.finish
    _, _, status = Contract.capture(@binary, 'key', '--pid', @window.pid.to_s, '--key', 'enter')
    expect(status).to eq(77)
    expect(@window.stdout.lines.grep(/^SENT /).length).to eq(1)
  ensure
    set_verifier(true) if @input
  end
end

RSpec.describe 'Linux input consent' do
  it 'requires an explicit request before opening an input session' do
    skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
    output, error, status = Contract.capture(File.join(Contract::ROOT, 'submodules/blindly4/.build/debug/blindly4-input'))
    expect(status).to eq(64), output + error
    expect(error).to include('--consent')
  end

  it 'does not treat a pointer flag as consent' do
    skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
    output, error, status = Contract.capture(File.join(Contract::ROOT, 'submodules/blindly4/.build/debug/blindly4-input'), '--pointer')
    expect(status).to eq(64), output + error
  end
end

RSpec.describe 'Linux desktop policy' do
  it 'refuses input when a locked GNOME policy disables the foreground extension' do
    skip 'Isolated policy session required' unless ENV['SAPIENS_TEST_LOCKDOWN'] == '1'
    output, error, status = Contract.capture('gsettings', 'writable', 'org.gnome.shell', 'disable-user-extensions')
    expect(status).to eq(0), error
    expect(output.strip).to eq('false')
    _, _, status = Contract.capture('gsettings', 'set', 'org.gnome.shell', 'disable-user-extensions', 'false')
    expect(status).not_to eq(0)
    fixture = Host.new(start: false)
    desktop = Contract::Child.new(File.join(Contract::ROOT, '.build/bin/sapiens-linux'),
      '--data-dir', fixture.root, env: fixture.environment)
    Contract.wait(description: 'desktop under lockdown') { desktop.stdout.include?('READY ') }
    driver = File.join(Contract::ROOT, 'submodules/blindly4/.build/debug/blindly4')
    output, error, status = Contract.capture(driver, 'request-permission')
    expect(status).to eq(0), output + error
    expect(JSON.parse(output)).to include('trusted' => true, 'foregroundAvailable' => false)
    %w[key click scroll].each do |operation|
      arguments = {'key' => %w[--key a], 'click' => %w[--x 0 --y 0], 'scroll' => %w[--direction down --amount 1]}.fetch(operation)
      output, error, status = Contract.capture(driver, operation, '--pid', desktop.pid.to_s, *arguments)
      expect(status).to eq(77), output + error
    end
    output, error, status = Contract.capture('gsettings', 'get', 'org.gnome.shell', 'disable-user-extensions')
    expect(status).to eq(0), error
    expect(output.strip).to eq('true')
  ensure
    desktop&.signal('TERM')
    desktop&.close
    fixture&.close
  end
end
