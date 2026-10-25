RSpec.describe 'UI navigation and request lifecycle' do
  before(:all) do
    out, error, code = Contract.capture('node', 'spec/support/ui-state.cjs', timeout: 30)
    raise out + error unless code.zero?
    @observed = JSON.parse(out)
  end

  it 'restores the saved work view and filter, rendering task text literally' do
    row = @observed.fetch('restored')
    expect(row).to include('panel' => 'work', 'filter' => 'Executed', 'scripts' => 0)
    expect(row['text']).to include('Saved task', '<script>literal YAML</script>')
  end

  it 'normalizes invalid saved navigation to a usable chat' do
    expect(@observed.fetch('invalid')).to eq('panel' => 'chat', 'errors' => [])
  end

  it 'rejects a saved Group-only task filter in a personal chat' do
    expect(@observed.fetch('filter')).to eq('text' => 'Planned', 'errors' => [])
  end

  it 'keeps desktop workspace visibility when moving from a Sapi without tabs to one with tabs' do
    expect(@observed.fetch('panes')).to eq('before' => true, 'after' => false, 'errors' => [])
  end

  it 'delivers a pending task result after leaving and returning to the view' do
    expect(@observed.fetch('remounted')).to include('requests' => 1, 'errors' => [])
    expect(@observed['remounted']['text']).to include('Returned task')
  end

  it 'ignores a late response from the previous corpora even for the same Sapi ID' do
    expect(@observed.fetch('switched')).to include('requests' => 2, 'errors' => [])
    expect(@observed['switched']['text']).to include('Current corpora')
    expect(@observed['switched']['text']).not_to include('Stale corpora')
  end

  it 'offers retry for failed and malformed responses and recovers without reload' do
    row = @observed.fetch('retry')
    expect(row).to include('requests' => 3, 'errors' => [])
    %w[failure malformed].each { |key| expect(row[key]).to include('Could not load tasks.', 'Try again') }
    expect(row['recovered']).to include('No planned tasks')
  end
end
