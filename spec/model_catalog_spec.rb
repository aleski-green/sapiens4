RSpec.describe 'Codex model discovery', :host do
  def model(id, **changes)
    {'model' => id, 'displayName' => id.capitalize, 'hidden' => false, 'isDefault' => false,
     'defaultReasoningEffort' => 'high',
     'supportedReasoningEfforts' => [{'reasoningEffort' => 'low'}, {'reasoningEffort' => 'high'}]}
      .merge(changes.transform_keys(&:to_s))
  end

  def requests
    path = File.join(host.root, 'discovery.jsonl')
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  it 'discovers all visible pages and model-specific efforts without starting work or changing settings' do
    before = host.state.fetch('orchestration')
    host.configure(catalog_pages: [
      {data: [model('general', isDefault: true), model('hidden', hidden: true)], nextCursor: '1'},
      {data: [model('quick', defaultReasoningEffort: 'low', supportedReasoningEfforts: [{reasoningEffort: 'low'}])], nextCursor: nil}
    ])
    rows = host.api('GET', '/api/providers/codex/models').fetch('data')
    expect(rows.map { |row| row.fetch('model') }).to eq(%w[general quick])
    expect(rows.first).to include('isDefault' => true, 'defaultReasoningEffort' => 'high', 'efforts' => %w[low high])
    expect(rows.last.fetch('efforts')).to eq(['low'])
    expect(requests.map { |request| request.fetch('method') }).to eq(%w[initialize initialized model/list model/list])
    expect(requests.select { |request| request['method'] == 'model/list' }.map { |request| request['params']['includeHidden'] }).to eq([false, false])
    expect(host.calls).to be_empty
    expect(host.state.fetch('orchestration')).to eq(before)
  end

  it 'returns an empty catalog without inventing fallback models' do
    host.configure(catalog_pages: [{data: [], nextCursor: nil}])
    expect(host.api('GET', '/api/providers/codex/models')).to eq('data' => [])
  end

  {
    'provider errors' => {catalog_error: true},
    'malformed JSON' => {catalog_malformed: true},
    'missing model metadata' => {catalog_pages: [{data: [{}]}]},
    'repeated cursors' => {catalog_pages: [{data: [], nextCursor: '1'}, {data: [], nextCursor: '1'}]}
  }.each do |name, configuration|
    it "reports #{name} and permits a fresh discovery attempt" do
      host.configure(**configuration)
      expect(host.request('GET', '/api/providers/codex/models').first).to eq(502)
      host.configure(catalog_error: false, catalog_malformed: false, catalog_pages: [{data: [model('recovered')]}])
      expect(host.api('GET', '/api/providers/codex/models').fetch('data').first.fetch('model')).to eq('recovered')
      expect(host.calls).to be_empty
    end
  end

  it 'keeps state requests responsive while discovery is waiting on the provider' do
    host.configure(catalog_block: true)
    discovery = Thread.new { host.api('GET', '/api/providers/codex/models') }
    Contract.wait(description: 'model list requested') { requests.any? { |request| request['method'] == 'model/list' } }
    Timeout.timeout(3) { expect(host.state.fetch('agents')).not_to be_empty }
    host.release
    expect(discovery.value.fetch('data')).not_to be_empty
  ensure
    host.release
    discovery.join if discovery
  end
  it 'terminates a stalled discovery process at the deadline' do
    host.configure(catalog_block: true)
    uri = URI(host.url + '/api/providers/codex/models')
    response = Net::HTTP.start(uri.host, uri.port, nil, read_timeout: 40) { |http| http.get(uri.request_uri) }
    expect(response.code.to_i).to eq(504)
    expect(JSON.parse(response.body).to_s).to include('timed out')
    pid = requests.first.fetch('pid')
    Contract.wait(description: 'discovery provider exit') do
      begin
        Process.kill(0, pid)
        false
      rescue Errno::ESRCH
        true
      end
    end
    expect(host.state.fetch('agents')).not_to be_empty
  end

end
