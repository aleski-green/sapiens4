RSpec.describe 'Chat position during live workspace updates' do
  before(:all) do
    out, error, code = Contract.capture('node', 'spec/support/chat-scroll.cjs')
    raise out + error unless code == 0
    @result = JSON.parse(out)
  end

  it 'leaves messages and momentum scrolling untouched on unrelated updates' do
    expect(@result['unrelated']).to eq('retained' => true, 'writes' => 0, 'scroll' => 220)
    expect(@result['errors']).to be_empty
  end

  it 'adds replies without interrupting someone reading earlier messages' do
    expect(@result['append']).to include('retained' => true, 'writes' => 0, 'scroll' => 220, 'messages' => 8)
  end

  it 'follows new replies when already at the bottom' do
    expect(@result['bottom']['scroll']).to eq(@result['bottom']['max'])
  end

  it 'updates changed replies without replacing other messages' do
    expect(@result['update']).to include('laterRetained' => true, 'scroll' => 220)
    expect(@result['update']['text']).to include('Changed reply')
  end

  it 'keeps the reading position, draft and composer focus when the same corpora reconnects' do
    expect(@result['reconnect']).to include('retained' => true, 'scroll' => 220, 'draft' => 'Keep my draft', 'focused' => true)
  end

  it 'keeps the visible message in place when older cached history arrives' do
    expect(@result['prepend']['retained']).to eq(true)
    expect(@result['prepend']['after']).to eq(@result['prepend']['offset'])
  end

  it 'opens an explicitly selected chat at its latest message' do
    expect(@result['navigate']['scroll']).to eq(@result['navigate']['max'])
  end

  it 'preserves existing group messages when another group reply arrives' do
    expect(@result['group']).to include('retained' => true, 'messages' => 3)
    expect(@result['group']['text']).to include('Another group reply')
  end
end
