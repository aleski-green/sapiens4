require 'yaml'

RSpec.describe 'Claude provider integration', :host do
  def selection(model = 'claude-opus-5-5', effort = 'medium')
    {provider: 'claude', model: model, effort: effort}
  end

  def apply_settings(defaults: selection, overrides: {}, revision: 0)
    host.api('PUT', '/api/model-settings', {revision: revision, defaults: defaults, overrides: overrides})
  end

  def catalog
    host.api('GET', '/api/providers/claude/models').fetch('data')
  end

  def requests
    path = File.join(host.root, 'claude-discovery.jsonl')
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def expect_claude(calls, model = 'claude-opus-5-5', effort = 'medium')
    expect(calls).not_to be_empty
    calls.each do |call|
      args = call.fetch('args')
      expect(call.fetch('provider')).to eq('claude')
      expect(args[args.index('--model') + 1]).to eq(model)
      expect(args).to include('--dangerously-skip-permissions', '--no-session-persistence')
      if effort.empty?
        expect(args).not_to include('--effort')
      else
        expect(args[args.index('--effort') + 1]).to eq(effort)
      end
    end
  end

  it 'discovers pinned models, deduplicates aliases and preserves missing effort support without starting work' do
    rows = catalog
    expect(rows.map { |row| row.fetch('model') }).to eq(%w[claude-opus-5-5 claude-fixture-no-effort])
    expect(rows.first).to include('displayName' => 'Opus 5.5', 'isDefault' => true, 'efforts' => %w[low medium high xhigh max])
    expect(rows.last).to include('efforts' => [], 'defaultReasoningEffort' => '')
    expect(requests.map { |r| r.fetch('type') }).to eq(['control_request'])
    expect(host.calls).to be_empty
  end

  {
    'provider error' => {claude_catalog_error: true},
    'malformed response' => {claude_catalog_malformed: true},
    'missing model metadata' => {claude_models: [{}]}
  }.each do |label, configuration|
    it "reports #{label} and permits discovery retry" do
      host.configure(**configuration)
      expect(host.request('GET', '/api/providers/claude/models').first).to eq(502)
      host.configure(claude_catalog_error: false, claude_catalog_malformed: false,
        claude_models: [{value: 'opus', resolvedModel: 'claude-opus-5-5', displayName: 'Opus 5.5', supportsEffort: true, supportedEffortLevels: ['medium']}])
      expect(catalog.first.fetch('model')).to eq('claude-opus-5-5')
    end
  end

  it 'returns an empty catalog without inventing models' do
    host.configure(claude_models: [])
    expect(catalog).to eq([])
  end

  it 'persists mixed providers, routes each Sapi correctly and does not require an unused provider' do
    agent = host.agent
    codex = {provider: 'codex', model: 'fixture-general', effort: 'high'}
    saved = apply_settings(overrides: {agent => codex})
    host.restart
    expect(host.api('GET', '/api/model-settings')).to eq(saved)
    host.turn(host.submit(chief))
    host.turn(host.submit(agent))
    expect_claude(host.calls.select { |call| call['owner'] == chief })
    calls = host.calls.select { |call| call['owner'] == agent }
    expect(calls).not_to be_empty
    calls.each { |call| expect(call.fetch('args')).to include('model="fixture-general"') }
    host.configure(claude_catalog_error: true)
    apply_settings(defaults: codex, revision: 1)
  end

  it 'omits effort for models without advertised effort support and rejects an explicit unsupported effort' do
    saved = apply_settings(defaults: selection('claude-fixture-no-effort', ''))
    code, = host.request('PUT', '/api/model-settings', {revision: 1, defaults: selection('claude-fixture-no-effort', 'medium'), overrides: {}})
    expect(code).to eq(400)
    expect(host.api('GET', '/api/model-settings')).to eq(saved)
    host.turn(host.submit(chief))
    expect_claude(host.calls, 'claude-fixture-no-effort', '')
  end

  it 'keeps Claude and audit records fixed through a running task when new settings switch to Codex' do
    apply_settings
    host.configure(mode: 'Exec', rules: {'Assessing' => {block: true}})
    first = host.submit(chief)
    Contract.wait(description: 'Claude invocation') { host.calls.any? }
    apply_settings(defaults: {provider: 'codex', model: 'fixture-general', effort: 'high'}, revision: 1)
    host.release
    host.turn(first)
    host.idle
    expect_claude(host.calls)
    tasks = YAML.safe_load(host.api('GET', "/api/agents/#{chief}/tasks")).fetch('tasks')
    records = tasks.flat_map { |task| task.fetch('decisions') }
    expect(records).not_to be_empty
    expect(records).to all(include('provider' => 'claude', 'model' => 'claude-opus-5-5', 'effort' => 'medium'))
    count = host.calls.size
    host.turn(host.submit(chief, 'Use Codex now'))
    expect(host.calls.drop(count).map { |call| call['provider'] }).to all(eq('codex'))
  end

  {'error result with successful process exit' => {claude_result_error: true},
   'intermediate text without a final result' => {claude_missing_result: true}}.each do |label, configuration|
    it "fails on #{label} instead of accepting intermediate text or falling back" do
      apply_settings
      host.configure(**configuration)
      host.turn(host.submit(chief), 'failed')
      expect_claude(host.calls)
    end
  end

  it 'allows workspace writes through the Claude process without changing the workspace or run identity' do
    apply_settings
    host.configure(rules: {'Assessing' => {actions: [{write: 'Notes.html', content: '<h1>Notes updated by the provider fixture</h1>'}]}})
    host.turn(host.submit(chief))
    call = host.calls.first
    expect(call.fetch('agency_run')).not_to be_empty
    expect(File.read(File.join(host.workspace(chief), 'Notes.html'))).to eq('<h1>Notes updated by the provider fixture</h1>')
    expect_claude(host.calls)
  end

  it 'creates a specialist through the existing decision flow using Claude' do
    apply_settings
    host.configure(mode: 'Exec', rules: {
      "#{chief}:Assessing" => {response: decision('OutsideSpecialization')},
      'ChiefTriage' => {response: decision('NewSpecialistNeeded')}})
    host.submit(chief)
    host.idle
    specialist = host.state.fetch('agents').find { |agent| agent['name'] == 'NewResearcher' }
    expect(specialist).not_to be_nil
    expect_claude(host.calls)
  end

  it 'stops a running Claude process when its turn is cancelled' do
    apply_settings
    host.configure(block: true)
    id = host.submit(chief)
    Contract.wait(description: 'blocked Claude process') { host.calls.any? }
    pid = host.calls.first.fetch('pid')
    host.api('POST', "/api/agents/#{chief}/turns/#{id}/cancel", {})
    host.turn(id, %w[interrupted cancelled])
    Contract.wait(description: 'Claude process exit') do
      begin
        Process.kill(0, pid)
        false
      rescue Errno::ESRCH
        true
      end
    end
  end

  it 'times out stalled discovery without locking the host and stops its process' do
    host.configure(claude_catalog_block: true)
    discovery = Thread.new do
      uri = URI(host.url + '/api/providers/claude/models')
      Net::HTTP.start(uri.host, uri.port, nil, read_timeout: 40) { |http| http.get(uri.request_uri) }
    end
    Contract.wait(description: 'Claude initialization') { requests.any? }
    Timeout.timeout(3) { expect(host.state.fetch('agents')).not_to be_empty }
    expect(discovery.value.code.to_i).to eq(504)
    pid = requests.first.fetch('pid')
    Contract.wait(description: 'discovery process exit') do
      begin
        Process.kill(0, pid)
        false
      rescue Errno::ESRCH
        true
      end
    end
  ensure
    host.release
    discovery.join if discovery
  end
end
