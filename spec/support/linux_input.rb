module LinuxInput
  def set_verifier(enabled)
    output, error, status = Contract.capture('gnome-extensions', enabled ? 'enable' : 'disable', 'foreground@blindly4.sapiens4')
    expect(status).to eq(0), output + error
    Contract.wait(description: "foreground verifier #{enabled ? 'enabled' : 'disabled'}") do
      _, _, status = Contract.capture('gdbus', 'call', '--session', '--dest', 'org.gnome.Shell',
        '--object-path', '/org/sapiens/Blindly/Foreground', '--method', 'org.sapiens.Blindly.Foreground1.Get')
      (status == 0) == enabled
    end
  end

  def overview(visible)
    output, error, status = Contract.capture('gdbus', 'call', '--session', '--dest', 'org.gnome.Shell',
      '--object-path', '/org/gnome/Shell', '--method', 'org.freedesktop.DBus.Properties.Set',
      'org.gnome.Shell', 'OverviewActive', "<#{visible}>")
    expect(status).to eq(0), output + error
  end

  def consent_input(binary:, pid: nil, pointer: false)
    @input = Contract::Child.new(File.join(File.dirname(binary), 'blindly4-input'), '--consent', *(['--pointer'] if pointer))
    portal_pid = nil
    Contract.wait(description: 'portal consent window') do
      output, _, status = Contract.capture('gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
        '--object-path', '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.GetConnectionUnixProcessID',
        'org.freedesktop.impl.portal.desktop.gnome')
      portal_pid = output[/uint32 (\d+)/, 1] if status == 0
    end
    consent = nil
    Contract.wait(description: 'native Share button') do
      raise @input.stderr unless @input.stderr.empty?
      output, _, status = Contract.capture(binary, 'find', '--pid', portal_pid, '--title', 'Share', '--role', 'Button', '--depth', '30')
      consent = JSON.parse(output).fetch('matches').first if status == 0
      consent
    end
    toggles = portal_command(binary, 'find', '--pid', portal_pid, '--role', 'CheckBox', '--depth', '30').fetch('matches')
    toggle = toggles.find { |node| node['subrole'] == 'switch' && node.fetch('actions').include?('AXPress') }
    expect(toggle).not_to be_nil
    portal_command(binary, 'press', '--pid', portal_pid, '--path', toggle.fetch('path'))
    Contract.wait(description: 'consent button enabled') do
      consent = portal_command(binary, 'find', '--pid', portal_pid, '--title', 'Share', '--role', 'Button', '--depth', '30').fetch('matches').find { |node| node['enabled'] }
    end
    portal_command(binary, 'press', '--pid', portal_pid, '--path', consent.fetch('path'))
    Contract.wait(description: 'consented input session') { @input.stdout.include?('READY keyboard') }
    if pid && ENV['SAPIENS_TEST_HEADLESS'] == '1'
      portal_command(binary, 'key', '--pid', pid.to_s, '--key', 'f24')
    end
  end

  def portal_command(binary, *arguments)
    output, error, status = Contract.capture(binary, *arguments)
    expect(status).to eq(0), output + error
    JSON.parse(output)
  end
end
