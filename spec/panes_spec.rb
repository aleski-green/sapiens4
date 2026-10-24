RSpec.describe 'Responsive workspace panels', :browser do
  before(:all) do
    out, error, code = Contract.capture('node', 'spec/support/panes-browser.cjs')
    raise out + error unless code == 0
    @panes = JSON.parse(out)
  end

  it 'keeps exactly the selected portrait panel visible, including repeated selections' do
    expect(@panes['initial']).to eq(['chat'])
    expect(@panes['selected']).to eq(%w[sidebar workspace chat].map { |pane|
      {'pane' => pane, 'opened' => [pane], 'repeated' => [pane]}
    })
    expect(@panes['mobile']).to eq(true)
  end

  it 'shows the destination panel when selecting a conversation or focusing a workspace' do
    expect(@panes['openChat']).to eq(['chat'])
    expect(@panes['focusWorkspace']).to eq(['workspace'])
    expect(@panes['rosterFilter']).to eq(['sidebar'])
  end

  it 'limits landscape to two panels, replacing the oldest and retaining the last open panel' do
    expect(@panes['rotatedLandscape']).to eq(%w[chat workspace])
    expect(@panes['thirdPane']).to eq(%w[sidebar chat])
    expect(@panes['closedChat']).to eq(['sidebar'])
    expect(@panes['lastPane']).to eq(['sidebar'])
    expect(@panes['landscape']).to eq('initial' => %w[sidebar chat], 'selected' => %w[chat workspace])
  end

  it 'keeps the selected panel through rotation and software keyboard resizing' do
    expect(@panes['rotatedPortrait']).to eq(['workspace'])
    expect(@panes['keyboard']).to eq('panes' => ['workspace'], 'limit' => '1')
  end

  it 'keeps a useful chat after closing the last tab or resetting the layout' do
    expect(@panes['closedLastTab']).to eq(['chat'])
    expect(@panes['resetLayout']).to eq(['chat'])
    expect(@panes['noTabs']).to eq('initial' => ['chat'], 'opened' => ['workspace'])
  end

  it 'focuses search and clears it with Escape' do
    expect(@panes['search']).to eq('focused' => 'agent-search', 'open' => true, 'closedValue' => '', 'expanded' => 'false')
  end

  it 'grows the mobile composer within its minimum and maximum height' do
    expect(@panes['composer']).to eq(%w[96px 140px 44px])
  end

  it 'opens the main menu and dispatches shared computer navigation once' do
    expect(@panes['menu']).to eq('open' => true, 'resource' => true, 'opened' => 1,
      'targets' => %w[workspace-settings resource-button])
  end

  it 'keeps all tab close controls accessible while only displaying the selected mobile tab' do
    expect(@panes['tabs']).to eq('overflowHidden' => false, 'selected' => 'Two', 'otherHidden' => true, 'closeButtons' => 2)
  end

  it 'supports narrow non-touch windows and all three independently toggled desktop panels' do
    expect(@panes['narrow']).to eq(['chat'])
    expect(@panes['desktop']).to eq('initial' => %w[sidebar chat workspace], 'closed' => %w[chat workspace],
      'reopened' => %w[sidebar chat workspace], 'mobile' => false)
  end
end
