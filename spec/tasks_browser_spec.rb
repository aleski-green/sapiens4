RSpec.describe 'Task browser behavior', :browser do
  before(:all) do
    out, error, code = Contract.capture('node', 'spec/support/tasks-browser.cjs')
    raise out + error unless code == 0
    @tasks = JSON.parse(out)
  end

  it 'requests the selected Sapi tasks and separates planned from terminal outcomes' do
    expect(@tasks['urls']).to eq(['/api/agents/chief/tasks?format=json'])
    expect(@tasks['planned']['count']).to eq(3)
    expect(@tasks['pastCount']).to eq(5)
  end

  it 'renders titles and YAML bodies literally without interpreting HTML' do
    expect(@tasks['planned']).to include('title' => 'Research <script>bad</script>', 'titleElements' => 0,
      'body' => "objective: \"<script>bad</script>\"\n", 'bodyElements' => 0)
  end

  it 'keeps the existing DOM when polling is unchanged and restores expansion after changing periods' do
    expect(@tasks['sameView']).to eq(true)
    expect(@tasks['expanded']).to eq(true)
    expect(@tasks['urls'].length).to eq(1)
  end

  it 'discards late responses after selecting another Sapi' do
    expect(@tasks['staleRows']).to eq(0)
  end

  it 'shows a retry action for a failed request and a useful empty state' do
    expect(@tasks['failed']).to eq('message' => 'Could not load tasks.', 'retry' => 'Try again')
    expect(@tasks['empty']).to eq('No planned tasks')
  end

  it 'attributes delegated work to its responsible Sapi and retains the running call' do
    expect(@tasks['delegation']).to eq('author' => 'researcher', 'sameTurn' => true, 'id' => 'w1')
  end
end
