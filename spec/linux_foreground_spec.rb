RSpec.describe 'GNOME foreground verification' do
  let(:installer) { File.join(Contract::ROOT, 'submodules/blindly4/linux/gnome/install.sh') }

  it 'requires explicit consent before installing the optional extension' do
    skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
    Dir.mktmpdir do |directory|
      _, error, status = Contract.capture('sh', installer, env: {'XDG_DATA_HOME' => directory})
      expect(status).to eq(64), error
      expect(error).to include('--accept-foreground-verification')
      expect(Dir.children(directory)).to be_empty
    end
  end

  it 'installs auditable source without enabling the extension' do
    skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
    Dir.mktmpdir do |directory|
      output, error, status = Contract.capture('sh', installer, '--accept-foreground-verification', '--shell-version', '46',
        env: {'XDG_DATA_HOME' => directory})
      expect(status).to eq(0), error
      installed = File.join(directory, 'gnome-shell/extensions/foreground@blindly4.sapiens4')
      expect(Dir.children(installed).sort).to eq(%w[extension.js metadata.json])
      expect(output).to include('gnome-extensions enable foreground@blindly4.sapiens4')
    end
  end

  %w[42 46].each do |version|
    it "installs only the explicitly selected GNOME #{version} loader without enabling it" do
      skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
      Dir.mktmpdir do |directory|
        output, error, status = Contract.capture('sh', installer, '--accept-foreground-verification', '--shell-version', version,
          env: {'XDG_DATA_HOME' => directory})
        expect(status).to eq(0), output + error
        installed = File.join(directory, 'gnome-shell/extensions/foreground@blindly4.sapiens4')
        expect(JSON.parse(File.read(File.join(installed, 'metadata.json'))).fetch('shell-version')).to eq([version])
        expect(Dir.children(installed).sort).to eq(%w[extension.js metadata.json])
      end
    end
  end

  it 'reports the foreground process and removes its API when disabled' do
    skip 'Isolated GNOME session required' unless ENV['SAPIENS_TEST_GNOME_FOREGROUND'] == '1'
    skip 'Wayland foreground contract' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
    fixture = Host.new(start: false)
    desktop = Contract::Child.new(File.join(Contract::ROOT, '.build/bin/sapiens-linux'),
      '--data-dir', fixture.root, env: fixture.environment)
    arguments = %w[gdbus call --session --dest org.gnome.Shell --object-path /org/sapiens/Blindly/Foreground --method org.sapiens.Blindly.Foreground1.Get]
    Contract.wait(description: 'foreground process reported by GNOME') do
      output, _, status = Contract.capture(*arguments)
      status == 0 && output == "(uint32 #{desktop.pid},)\n"
    end
    output, error, status = Contract.capture('gnome-extensions', 'disable', 'foreground@blindly4.sapiens4')
    expect(status).to eq(0), output + error
    Contract.wait(description: 'disabled foreground API') { Contract.capture(*arguments).last != 0 }
  rescue StandardError
    warn "Desktop: #{desktop.stdout}\n#{desktop.stderr}" if desktop
    raise
  ensure
    Contract.capture('gnome-extensions', 'enable', 'foreground@blindly4.sapiens4') if desktop
    desktop&.signal('TERM')
    desktop&.close
    fixture&.close
  end

  it 'does not trust X11 window PID metadata through the Wayland extension' do
    skip 'Isolated Xorg session with extension required' unless ENV['SAPIENS_TEST_GNOME_FOREGROUND'] == '1' && ENV['XDG_SESSION_TYPE'] == 'x11'
    fixture = Host.new(start: false)
    desktop = Contract::Child.new(File.join(Contract::ROOT, '.build/bin/sapiens-linux'), '--data-dir', fixture.root, env: fixture.environment)
    driver = File.join(Contract::ROOT, 'submodules/blindly4/.build/debug/blindly4')
    Contract.wait(description: 'real Xorg foreground window') do
      output, _, status = Contract.capture(driver, 'apps')
      status == 0 && JSON.parse(output).fetch('apps').any? { |app| app['pid'] == desktop.pid && app['frontmost'] }
    end
    output, error, status = Contract.capture('gdbus', 'call', '--session', '--dest', 'org.gnome.Shell',
      '--object-path', '/org/sapiens/Blindly/Foreground', '--method', 'org.sapiens.Blindly.Foreground1.Get')
    expect(status).to eq(0), error
    expect(output).to eq("(uint32 0,)\n")
  ensure
    desktop&.signal('TERM')
    desktop&.close
    fixture&.close
  end
end
