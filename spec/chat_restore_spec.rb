RSpec.describe 'Reopening a chat from its offline cache' do
  before(:all) do
    out, error, code = Contract.capture('node', 'spec/support/chat-restore.cjs')
    raise out + error unless code == 0
    @result = JSON.parse(out)
  end

  it 'restores the same message and offset despite a shorter cached transcript' do
    result = @result['cached']
    expect(result['before']).to eq(result['expected'])
    expect(result['after']).to eq(result['expected'])
    expect(result['draft']).to eq('My unsent draft')
  end

  it 'waits for live history if the saved message is absent from the cache' do
    result = @result['missing']
    expect(result['pending']['key']).not_to be_nil
    expect(result['after']).to eq(result['expected'])
  end

  it 'honors reading gestures made while waiting for live history' do
    expect(@result['manual']['after']).to eq(@result['manual']['before'])
  end

  it 'keeps the latest messages visible after restoring a bottom position' do
    expect(@result['bottom']['scroll']).to eq(@result['bottom']['max'])
  end
end
