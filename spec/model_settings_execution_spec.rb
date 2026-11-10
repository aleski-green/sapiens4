require 'yaml'

RSpec.describe 'Applied Codex model settings', :host do
  def choice(model = 'gpt-6-astra', effort = 'medium')
    {provider: 'codex', model: model, effort: effort}
  end

  def settings(revision: 0, defaults: choice, overrides: {})
    {revision: revision, defaults: defaults, overrides: overrides}
  end

  def apply_settings(**fields)
    host.api('PUT', '/api/model-settings', settings(**fields))
  end

  def expect_calls(calls, model, effort)
    expect(calls).not_to be_empty
    calls.each do |call|
      expect(call.fetch('args')).to include("model=\"#{model}\"", "model_reasoning_effort=\"#{effort}\"",
        '--dangerously-bypass-approvals-and-sandbox')
    end
  end

  before do
    host.configure(catalog_pages: [{data: [
      {model: 'gpt-6-astra', displayName: 'Astra', hidden: false, isDefault: false,
       defaultReasoningEffort: 'low', supportedReasoningEfforts: [{reasoningEffort: 'low'}, {reasoningEffort: 'medium'}]},
      {model: 'fixture-quick', displayName: 'Quick', hidden: false, isDefault: true,
       defaultReasoningEffort: 'low', supportedReasoningEfforts: [{reasoningEffort: 'low'}]}
    ]}])
  end

  it 'offers an old draft for review without activating it, then applies it explicitly' do
    draft = host.api('PUT', '/api/model-settings-draft', settings(defaults: choice('fixture-quick', 'low')))
    offered = host.api('GET', '/api/model-settings')
    expect(offered).to eq(draft.merge('revision' => 0))
    expect(File.exist?(File.join(host.root, 'model-settings.json'))).to eq(false)
    host.turn(host.submit(chief, 'Before applying'))
    expect_calls(host.calls, 'gpt-6-sol', 'high')
    first_count = host.calls.size
    host.api('PUT', '/api/model-settings', offered)
    host.turn(host.submit(chief, 'After applying'))
    expect_calls(host.calls.drop(first_count), 'fixture-quick', 'low')
    expect(host.api('GET', '/api/model-settings-draft')).to eq(draft)
  end

  it 'persists defaults and Sapi overrides, respects explicit effort over Deep, and restores inheritance' do
    agent = host.agent
    host.api('PUT', "/api/agents/#{agent}", name: 'Researcher', role: 'Research', execution: {mode: 'deep'})
    saved = apply_settings(overrides: {agent => choice('fixture-quick', 'low')})
    host.restart
    expect(host.api('GET', '/api/model-settings')).to eq(saved)
    host.turn(host.submit(chief, 'Use the corpora default'))
    host.turn(host.submit(agent, 'Use my override'))
    expect_calls(host.calls.select { |call| call['owner'] == chief }, 'gpt-6-astra', 'medium')
    expect_calls(host.calls.select { |call| call['owner'] == agent }, 'fixture-quick', 'low')
    count = host.calls.size
    apply_settings(revision: 1)
    host.turn(host.submit(agent, 'Inherit the corpora default'))
    expect_calls(host.calls.drop(count), 'gpt-6-astra', 'medium')
  end

  {'legacy settings' => false, 'previously applied settings' => true}.each do |label, already_applied|
    it "keeps #{label} for every step and audit record of a running task while new runs use the update" do
      apply_settings if already_applied
      expected_model = already_applied ? 'gpt-6-astra' : 'gpt-6-sol'
      expected_effort = already_applied ? 'medium' : 'high'
      host.configure(mode: 'Exec', rules: {'Assessing' => {block: true}})
      first = host.submit(chief, 'Keep this run consistent')
      Contract.wait(description: 'first model invocation') { host.calls.any? }
      run = host.calls.first.fetch('agency_run')
      apply_settings(revision: already_applied ? 1 : 0, defaults: choice('fixture-quick', 'low'))
      host.release
      host.turn(first)
      host.idle
      calls = host.calls.select { |call| call['agency_run'] == run }
      expect(calls.map { |call| call['node'] }).to include('Assessing', 'ReadyToWork', 'Execution')
      expect_calls(calls, expected_model, expected_effort)
      tasks = YAML.safe_load(host.api('GET', "/api/agents/#{chief}/tasks")).fetch('tasks')
      records = tasks.flat_map { |task| task.fetch('decisions') }
      expect(records).not_to be_empty
      expect(records).to all(include('model' => expected_model, 'effort' => expected_effort))
      count = host.calls.size
      host.turn(host.submit(chief, 'Use the new settings'))
      expect_calls(host.calls.drop(count), 'fixture-quick', 'low')
    end
  end

  {
    'stale revision' => [{revision: 0}, 409],
    'unsupported effort' => [{defaults: {provider: 'codex', model: 'fixture-quick', effort: 'medium'}}, 400],
    'unknown provider' => [{defaults: {provider: 'unknown', model: 'unsupported', effort: 'medium'}}, 400],
    'nonexistent Sapi' => [{overrides: {'missing-sapi' => {provider: 'codex', model: 'gpt-6-astra', effort: 'medium'}}}, 404]
  }.each do |label, (changes, status)|
    it "rejects #{label} without replacing active settings" do
      saved = apply_settings
      expect(host.request('PUT', '/api/model-settings', settings(revision: 1).merge(changes)).first).to eq(status)
      expect(host.api('GET', '/api/model-settings')).to eq(saved)
    end
  end

  it 'preserves active settings when catalog validation fails and executes without rediscovery' do
    saved = apply_settings
    host.configure(catalog_error: true)
    expect(host.request('PUT', '/api/model-settings', settings(revision: 1)).first).to eq(502)
    expect(host.api('GET', '/api/model-settings')).to eq(saved)
    before = File.read(File.join(host.root, 'discovery.jsonl'))
    host.turn(host.submit(chief))
    expect_calls(host.calls, 'gpt-6-astra', 'medium')
    expect(File.read(File.join(host.root, 'discovery.jsonl'))).to eq(before)
  end

  it 'does not hold the state lock while validating a save with the provider' do
    host.configure(catalog_block: true)
    saving = Thread.new { apply_settings }
    begin
      Contract.wait(description: 'catalog validation request') do
        path = File.join(host.root, 'discovery.jsonl')
        File.exist?(path) && File.read(path).include?('model/list')
      end
      expect(host.api('GET', '/api/model-settings').fetch('revision')).to eq(0)
      expect(host.state.fetch('agents')).not_to be_empty
      expect(saving.alive?).to eq(true)
    ensure
      host.release
      saving.join
    end
    expect(saving.value.fetch('revision')).to eq(1)
  end

  it 'reports provider execution failure without silently falling back to another model' do
    apply_settings(defaults: choice('fixture-quick', 'low'))
    host.configure(fail: true)
    host.turn(host.submit(chief), 'failed')
    expect_calls(host.calls, 'fixture-quick', 'low')
  end
end
