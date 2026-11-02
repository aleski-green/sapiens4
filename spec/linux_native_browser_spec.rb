require_relative 'support/http_peer'
require_relative 'support/linux_input'

RSpec.describe 'Linux external desktop browsers' do
  include LinuxInput
  %w[chromium firefox].each do |engine|
    context engine do
      before do
        skip 'Isolated external desktop browser session required' unless ENV['SAPIENS_TEST_LINUX_EXTERNAL_DESKTOP'] == '1'
        @driver = File.join(Contract::ROOT, 'submodules/blindly4/.build/debug/blindly4')
        consent_input(binary: @driver) if ENV['XDG_SESSION_TYPE'] == 'wayland' && !RSpec.current_example.metadata[:no_consent]
        blocked = RSpec.current_example.metadata[:block_input] ? ' onkeydown="event.preventDefault()"' : ''
        @pages = HTTPPeer.new do |_request|
          [200, '<title>Native browser fixture</title><form method="post" action="/send"><label>Draft<input name="draft" value="Fixture draft"' + blocked + '></label><button>Send</button></form><label>Secret<input type="password" value="fixture-secret"></label>',
            {'Content-Type' => 'text/html; charset=utf-8'}]
        end
        @browser = Contract::Child.new('node', File.join(Contract::ROOT, 'spec/support/DesktopBrowser.cjs'), engine, @pages.url,
          env: {'PLAYWRIGHT_BROWSERS_PATH' => File.join(Contract::ROOT, 'submodules/libs4/.cache/playwright')})
        Contract.wait(description: "#{engine} readiness") do
          raise @browser.stderr unless @browser.stderr.empty?
          @pid = @browser.stdout[/READY (\d+)/, 1]
        end
        Contract.wait(description: "#{engine} native draft") do
          output, _, status = command('find', '--title', 'Draft', '--role', 'TextField', '--depth', '40')
          @draft = JSON.parse(output).fetch('matches').first if status == 0
        end
      end

      after do
        if RSpec.current_example.exception && @draft
          warn command('inspect', '--path', @draft.fetch('path')).first
          warn command('focused').first
        end
        @browser&.close
        @input&.signal('TERM')
        @input&.close
        @pages&.close
      end

      def command(operation, *arguments)
        Contract.capture(@driver, operation, '--pid', @pid, *arguments, env: {'BLINDLY4_LINUX_TEXT_INPUT' => 'keyboard'})
      end

      it 'reads the native page and refuses submission with a mismatched draft' do
        output, error, status = command('inspect', '--path', @draft.fetch('path'))
        expect(status).to eq(0), output + error
        expect(JSON.parse(output).fetch('value')).to eq('Fixture draft')
        output, error, status = command('find', '--title', 'Send', '--role', 'Button', '--depth', '40')
        expect(status).to eq(0), output + error
        send = JSON.parse(output).fetch('matches').first
        output, error, status = command('press', '--path', send.fetch('path'),
          '--require-value-path', @draft.fetch('path'), '--require-value', 'Wrong draft')
        expect(status).to eq(77), output + error
        expect(@pages.requests.none? { |request| request[:method] == 'POST' }).to eq(true)
      end

      it 'verifies replacement, typing into an empty draft and subsequent typed text' do
        portal_command(@driver, 'key', '--pid', @pid, '--key', 'f24') if ENV['SAPIENS_TEST_HEADLESS'] == '1'
        output, error, status = command('set-value', '--path', @draft.fetch('path'), '--value', 'Replacement')
        expect(status).to eq(0), output + error
        output, error, status = command('set-value', '--path', @draft.fetch('path'), '--value', '')
        expect(status).to eq(0), output + error
        output, error, status = command('type', '--text', 'Replacement')
        expect(status).to eq(0), output + error
        output, error, status = command('type', '--text', ' suffix')
        expect(status).to eq(0), output + error
        output, error, status = command('inspect', '--path', @draft.fetch('path'))
        expect(status).to eq(0), output + error
        expect(JSON.parse(output).fetch('value')).to eq('Replacement suffix')
        expect(@pages.requests.none? { |request| request[:method] == 'POST' }).to eq(true)
      end

      it 'reports failure when the browser refuses typed text', :block_input do
        portal_command(@driver, 'key', '--pid', @pid, '--key', 'f24') if ENV['SAPIENS_TEST_HEADLESS'] == '1'
        output, error, status = command('focus', '--path', @draft.fetch('path'))
        expect(status).to eq(0), output + error
        output, error, status = command('type', '--text', 'blocked')
        expect(status).to eq(77), output + error
        output, error, status = command('inspect', '--path', @draft.fetch('path'))
        expect(status).to eq(0), output + error
        expect(JSON.parse(output).fetch('value')).to eq('Fixture draft')
      end

      it 'refuses keyboard transport to a password field and redacts its value' do
        output, error, status = command('find', '--role', 'SecureTextField', '--depth', '40')
        expect(status).to eq(0), output + error
        secret = JSON.parse(output).fetch('matches').first
        expect(secret.fetch('value')).to be_nil
        output, error, status = command('paste', '--target-path', secret.fetch('path'), '--text', 'Replacement')
        expect(status).to eq(64), output + error
        expect(output + error).not_to include('fixture-secret')
        expect(@pages.requests.none? { |request| request[:method] == 'POST' }).to eq(true)
      end

      it 'rejects unsupported keyboard text before clearing the draft' do
        values = ["line\nbreak", "tab\tkey", "x" * 4097, 'Café العربية 🐧']
        values.each do |text|
          output, error, status = command('paste', '--target-path', @draft.fetch('path'), '--text', text)
          expect(status).to eq(64), output + error
          output, error, status = command('inspect', '--path', @draft.fetch('path'))
          expect(status).to eq(0), output + error
          expect(JSON.parse(output).fetch('value')).to eq('Fixture draft')
        end
        expect(@pages.requests.none? { |request| request[:method] == 'POST' }).to eq(true)
      end

      it 'refuses an unqualified keyboard layout before changing the draft' do
        skip 'Wayland layout restriction' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
        output, error, status = Contract.capture('gsettings', 'set', 'org.gnome.desktop.input-sources', 'sources', "[('xkb', 'fr')]")
        expect(status).to eq(0), output + error
        output, error, status = command('paste', '--target-path', @draft.fetch('path'), '--text', 'Replacement')
        expect(status).to eq(77), output + error
        output, error, status = command('inspect', '--path', @draft.fetch('path'))
        expect(status).to eq(0), output + error
        expect(JSON.parse(output).fetch('value')).to eq('Fixture draft')
      ensure
        Contract.capture('gsettings', 'set', 'org.gnome.desktop.input-sources', 'sources', "[('xkb', 'us')]") if ENV['XDG_SESSION_TYPE'] == 'wayland'
      end

      it 'requires portal consent before clearing the draft', :no_consent do
        skip 'Wayland portal only' unless ENV['XDG_SESSION_TYPE'] == 'wayland'
        output, error, status = command('paste', '--target-path', @draft.fetch('path'), '--text', 'Replacement')
        expect(status).to eq(77), output + error
        output, error, status = command('inspect', '--path', @draft.fetch('path'))
        expect(status).to eq(0), output + error
        expect(JSON.parse(output).fetch('value')).to eq('Fixture draft')
        expect(@pages.requests.none? { |request| request[:method] == 'POST' }).to eq(true)
      end

      it 'replaces and submits an exact draft through consented native keyboard input' do
        portal_command(@driver, 'key', '--pid', @pid, '--key', 'f24') if ENV['SAPIENS_TEST_HEADLESS'] == '1'
        text = 'Reviewed draft: Linux #42!'
        output, error, status = command('paste', '--target-path', @draft.fetch('path'), '--text', text)
        expect(status).to eq(0), output + error
        expect(JSON.parse(output).fetch('verified')).to eq(true)
        output, error, status = command('find', '--title', 'Send', '--role', 'Button', '--depth', '40')
        expect(status).to eq(0), output + error
        send = JSON.parse(output).fetch('matches').first
        output, error, status = command('press', '--path', send.fetch('path'),
          '--require-value-path', @draft.fetch('path'), '--require-value', text)
        expect(status).to eq(0), output + error
        Contract.wait(description: "#{engine} submission") { @pages.requests.any? { |request| request[:method] == 'POST' } }
        submitted = @pages.requests.select { |request| request[:method] == 'POST' }
        expect(submitted.length).to eq(1)
        expect(URI.decode_www_form(submitted.first.fetch(:body)).to_h).to eq('draft' => text)
      end
    end
  end
end
