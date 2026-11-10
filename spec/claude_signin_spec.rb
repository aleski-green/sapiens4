require_relative 'spec_helper'

RSpec.describe 'Claude sign-in inside Sapiens' do
  def claude(host)
    host.api('GET', '/api/host/onboarding').fetch('claude')
  end

  def gone?(pid)
    Process.kill(0, pid)
    false
  rescue Errno::ESRCH
    true
  end

  it "connects Claude in Sapiens' own folder and disconnects without touching the person's own Claude login" do
    skip 'The fixture executable uses a POSIX script' if Gem.win_platform?
    host = Host.new(start: false)
    personal = File.join(host.root, 'personal-claude')
    FileUtils.mkdir_p(personal)
    File.write(File.join(personal, '.fixture-login'), 'personal login')
    host.environment.merge!('CLAUDE_CONFIG_DIR' => personal,
      'ANTHROPIC_API_KEY' => 'synthetic-key-must-not-be-used', 'CLAUDE_CODE_OAUTH_TOKEN' => 'synthetic-token-must-not-be-used')
    host.configure(claude_accounts: true)
    host.start
    sapiens_home = File.join(host.environment.fetch('SAPIENS_CONFIG_DIR'), 'claude')

    expect(claude(host)).to include('status' => 'sign_in_required')
    host.api('POST', '/api/host/onboarding', {action: 'claude-sign-out'}, status: 409)

    expect(host.api('POST', '/api/host/onboarding', action: 'claude-connect').dig('claude', 'status')).to eq('signing_in')
    link = Contract.wait { url = claude(host).dig('login', 'url'); url unless url.to_s.empty? }
    expect(link).to start_with('https://claude.com/cai/oauth/authorize?')
    host.api('POST', '/api/host/onboarding', {action: 'claude-connect'}, status: 409)

    host.release('claude-login-approved')
    Contract.wait { claude(host)['status'] == 'signed_in' }
    expect(claude(host).dig('login', 'state')).to eq('complete')
    expect(File.exist?(File.join(sapiens_home, '.fixture-login'))).to eq(true)
    expect(File.stat(sapiens_home).mode & 0777).to eq(0700)

    host.api('POST', '/api/host/onboarding', action: 'claude-sign-out')
    Contract.wait { claude(host).dig('login', 'state') == 'signed_out' }
    expect(claude(host)['status']).to eq('sign_in_required')

    expect(File.read(File.join(personal, '.fixture-login'))).to eq('personal login')
    calls = File.readlines(File.join(host.root, 'claude-auth.jsonl')).map { |line| JSON.parse(line) }
    expect(calls.map { |call| call['args'][1] }.uniq.sort).to eq(%w[login logout status])
    expect(calls.map { |call| call['home'] }.uniq).to eq([sapiens_home])
    expect(calls.flat_map { |call| call['inherited'] }).to be_empty
  ensure
    host&.close
  end

  it 'cancels a Claude sign-in that is waiting for the browser' do
    skip 'The fixture executable uses a POSIX script' if Gem.win_platform?
    host = Host.new(start: false)
    host.configure(claude_accounts: true)
    host.start
    host.api('POST', '/api/host/onboarding', action: 'claude-connect')
    Contract.wait { !claude(host).dig('login', 'url').to_s.empty? }
    login = File.readlines(File.join(host.root, 'claude-auth.jsonl')).map { |line| JSON.parse(line) }.reverse.find { |call| call['args'][1] == 'login' }

    expect(host.api('POST', '/api/host/onboarding', action: 'claude-cancel').dig('claude', 'login', 'state')).to eq('cancelled')
    Contract.wait { gone?(login.fetch('pid')) }
    expect(claude(host)['status']).to eq('sign_in_required')
    host.api('POST', '/api/host/onboarding', {action: 'claude-cancel'}, status: 409)

    # Cancelling frees the Claude account lock, so a new sign-in can start; a failed one says so.
    host.release('claude-login-fails')
    host.api('POST', '/api/host/onboarding', action: 'claude-connect')
    Contract.wait { claude(host).dig('login', 'state') == 'failed' }
    expect(claude(host)['status']).to eq('sign_in_required')
  ensure
    host&.close
  end

  it 'stops a Claude task straight away with a clear message until Claude is connected' do
    skip 'The fixture executable uses a POSIX script' if Gem.win_platform?
    host = Host.new(start: false)
    host.configure(claude_accounts: true)
    host.start
    host.api('PUT', '/api/model-settings', {revision: 0, defaults: {provider: 'claude', model: 'claude-opus-5-5', effort: 'medium'}, overrides: {}})
    chief = host.state.fetch('main_agent_id')

    code, value, = host.request('POST', "/api/agents/#{chief}/messages", {text: 'Hello from a disconnected Claude'})
    expect(code).to eq(409)
    expect(value.fetch('error')).to eq("Claude isn't connected. Connect it in AI Connections, then try again.")
    expect(host.calls).to be_empty

    host.release('claude-login-approved')
    host.api('POST', '/api/host/onboarding', action: 'claude-connect')
    Contract.wait { claude(host)['status'] == 'signed_in' }
    host.turn(host.submit(chief, 'Hello from a connected Claude'))
  ensure
    host&.close
  end
end
