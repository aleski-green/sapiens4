require 'sqlite3'

RSpec.describe 'Domain validation through saved installation fixtures', :host do
  before do
    @owner = chief
    host.api('PUT', '/api/corpora/lifecycle', {action: 'pause', operation: 'fixture-pause', revision: host.state['corpora']['revision']})
    @file = File.join(host.root, 'agentpy/agents', @owner, 'state.json')
    @state = JSON.parse(File.read(@file))
    @turn = {id: 'fixture-call', flow: 'chat', input: 'Saved request', status: 'failed', attempt: 3,
      created: '2026-10-27T12:00:00+00:00', extension: {kept: true}}
  end

  {
    'unknown status' => {status: 'runing'}, 'unknown flow' => {flow: 'unknown'},
    'nontext input' => {input: true}, 'text attempt' => {attempt: 'three'},
    'negative attempt' => {attempt: -1}, 'fractional attempt' => {attempt: 1.5}
  }.each do |behavior, fields|
    it "reports #{behavior} in saved work instead of substituting a default" do
      Contract.atomic_json(@file, @state.merge('turns' => [@turn.merge(fields)]))
      code, body = host.request('GET', '/api/state')
      expect(code).to eq(500)
      expect(body['error']).not_to be_empty
      expect(host.calls).to be_empty
    end
  end

  it 'rejects a malformed saved turns collection' do
    Contract.atomic_json(@file, @state.merge('turns' => 'invalid'))
    expect(host.request('GET', '/api/state').first).to eq(500)
    expect(host.calls).to be_empty
  end

  it 'preserves unknown turn metadata when a lifecycle action saves the record' do
    Contract.atomic_json(@file, @state.merge('turns' => [@turn]))
    host.api('PUT', '/api/corpora/lifecycle', {action: 'activate', operation: 'fixture-resume', revision: host.state['corpora']['revision']})
    host.api('POST', "/api/agents/#{@owner}/turns/fixture-call/cancel", {})
    saved = JSON.parse(File.read(@file))['turns'].first
    expect(saved).to eq(JSON.parse(JSON.generate(@turn.merge(status: 'cancelled'))))
    expect(host.calls).to be_empty
  end

  it 'reports an unknown saved execution mode instead of silently choosing normal mode' do
    Contract.atomic_json(File.join(File.dirname(@file), 'run-settings.json'), {mode: 'deeep'})
    expect(host.request('GET', '/api/state').first).to eq(500)
    expect(host.calls).to be_empty
  end

  it 'rejects an empty saved workload history and keeps the health endpoint available' do
    SQLite3::Database.open(File.join(host.root, 'corpora.sqlite3')) do |db|
      db.execute('INSERT INTO workloads VALUES (?, ?)', ['fixture-work', JSON.generate(workloadId: 'fixture-work', tracked: true, calls: [])])
    end
    code, body = host.request('GET', '/api/state')
    expect(code).to eq(500)
    expect(body['error']).not_to be_empty
    expect(host.request('GET', '/api/health').first).to eq(200)
  end
end
