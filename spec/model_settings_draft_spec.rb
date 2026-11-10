RSpec.describe 'Saved model configuration drafts', :host do
  def selection(model = 'gpt-6-astra', effort = 'medium')
    {provider: 'codex', model: model, effort: effort}
  end

  def payload(revision: 0, defaults: selection, overrides: {})
    {revision: revision, defaults: defaults, overrides: overrides}
  end

  def current
    host.api('GET', '/api/model-settings-draft')
  end

  before do
    host.configure(catalog_pages: [{data: [
      {model: 'gpt-6-astra', displayName: 'Astra', hidden: false, isDefault: false,
       defaultReasoningEffort: 'low', supportedReasoningEfforts: [{reasoningEffort: 'low'}, {reasoningEffort: 'medium'}]},
      {model: 'fixture-quick', displayName: 'Quick', hidden: false, isDefault: true,
       defaultReasoningEffort: 'low', supportedReasoningEfforts: [{reasoningEffort: 'low'}]}
    ]}])
  end

  it 'offers the product recommendation without writing or changing execution defaults' do
    expect(current).to eq(JSON.parse(JSON.generate(payload)))
    expect(File.exist?(File.join(host.root, 'model-settings-draft.json'))).to eq(false)
    expect(host.calls).to be_empty
    expect(host.state.fetch('orchestration').fetch(chief).fetch('execution').fetch('mode')).to eq('normal')
  end

  it 'persists defaults and per-Sapi overrides across restart and supports removing an override' do
    agent = host.agent
    saved = host.api('PUT', '/api/model-settings-draft', payload(overrides: {agent => selection('fixture-quick', 'low')}))
    expect(saved.fetch('revision')).to eq(1)
    host.restart
    expect(current).to eq(saved)
    removed = host.api('PUT', '/api/model-settings-draft', payload(revision: 1))
    expect(removed).to include('revision' => 2, 'overrides' => {})
    host.restart
    expect(current).to eq(removed)
  end

  it 'does not activate the saved draft for model execution' do
    original = host.state.fetch('orchestration')
    host.api('PUT', '/api/model-settings-draft', payload)
    expect(host.state.fetch('orchestration')).to eq(original)
    host.turn(host.submit(chief, 'Check existing execution settings'))
    expect(host.calls).not_to be_empty
    expect(host.calls.first.fetch('args')).to include('model="gpt-6-sol"', 'model_reasoning_effort="high"')
  end

  it 'rejects a stale revision without replacing the saved draft' do
    saved = host.api('PUT', '/api/model-settings-draft', payload)
    expect(host.request('PUT', '/api/model-settings-draft', payload(defaults: selection('fixture-quick', 'low'))).first).to eq(409)
    expect(current).to eq(saved)
  end

  {
    'unknown model' => {defaults: {provider: 'codex', model: 'missing', effort: 'medium'}},
    'unsupported effort' => {defaults: {provider: 'codex', model: 'fixture-quick', effort: 'medium'}},
    'unknown provider' => {defaults: {provider: 'unknown', model: 'unsupported', effort: 'medium'}},
    'missing model' => {defaults: {provider: 'codex', effort: 'medium'}},
    'unknown setting' => {yolo: false},
    'negative revision' => {revision: -1},
    'fractional revision' => {revision: 0.5},
    'invalid override' => {overrides: {'missing' => {provider: 'codex', model: 'fixture-quick', effort: 'medium'}}}
  }.each do |description, changes|
    it "rejects #{description} without saving" do
      original = current
      expect(host.request('PUT', '/api/model-settings-draft', payload.merge(changes)).first).to eq(400)
      expect(current).to eq(original)
      expect(File.exist?(File.join(host.root, 'model-settings-draft.json'))).to eq(false)
    end
  end

  it 'rejects an override for a nonexistent Sapi' do
    expect(host.request('PUT', '/api/model-settings-draft', payload(overrides: {'missing' => selection})).first).to eq(404)
    expect(current.fetch('revision')).to eq(0)
  end

  it 'preserves a saved draft when provider discovery fails during a later save' do
    saved = host.api('PUT', '/api/model-settings-draft', payload)
    host.configure(catalog_error: true)
    expect(host.request('PUT', '/api/model-settings-draft', payload(revision: 1)).first).to eq(502)
    expect(current).to eq(saved)
  end
end
