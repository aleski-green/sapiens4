RSpec.describe 'Provider preflight process' do
  before { @host = Host.new(start: false) }
  after { @host.close }

  def probe(env = {})
    Contract.capture(Contract::PYTHON, '-m', 'sapiens.preflight', env: @host.environment.merge(env))
  end

  {
    'old CLI' => [{version: 'codex-cli 0.100.0'}, 'too old'],
    'unknown version output' => [{version: 'different-cli 9.0.0'}, 'Could not read'],
    'missing authentication' => [{login_exit: 1}, 'not signed in'],
    'rejected model call' => [{fail: true}, 'model check failed'],
    'unexpected response' => [{preflight_reply: 'NO'}, 'unexpected reply']
  }.each do |behavior, (config, message)|
    it "reports #{behavior} without activating an installation" do
      @host.configure(**config)
      _, error, code = probe
      expect(code).to eq(1)
      expect(error).to include(message)
      expect(File.exist?(File.join(@host.root, 'current.json'))).to eq(false)
      expect(@host.calls).to be_empty if ['old CLI', 'unknown version output', 'missing authentication'].include?(behavior)
    end
  end

  it 'rejects an explicit missing binary instead of falling back to a real installed provider' do
    _, error, code = probe('SAPIENS_CODEX_BINARY' => File.join(@host.root, 'missing'))
    expect(code).to eq(1)
    expect(error).to include('not found')
    expect(@host.calls).to be_empty
  end

  ['codex-cli 0.158.0', 'codex-cli 0.159.0-alpha.1'].each do |version|
    it "probes #{version} with configured model and effort in an isolated read-only workdir" do
      @host.configure(version: version)
      text, error, code = probe('SAPIENS_CODEX_MODEL' => 'fixture-model', 'SAPIENS_CODEX_REASONING_EFFORT' => 'xhigh')
      expect(code).to eq(0), error
      expect(text).to include('fixture-model / xhigh verified')
      call = @host.calls.fetch(0)
      expect(call['args']).to include('--ephemeral', '--sandbox', 'read-only', 'approval_policy="never"',
        'model="fixture-model"', 'model_reasoning_effort="xhigh"')
      expect(call['cwd']).not_to eq(Contract::ROOT)
      expect(File.exist?(call['cwd'])).to eq(false)
    end
  end
end
