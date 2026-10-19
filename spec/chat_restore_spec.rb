RSpec.describe 'Reopening a chat from its offline cache' do
  before(:all) do
    out, error, code = Contract.capture('node', 'spec/support/chat-restore.cjs')
    raise out + error unless code == 0
    @result = JSON.parse(out)
  end

  it 'restores the visible message despite hidden iOS layout changes and a shorter cache' do
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

  it 'restores a deliberate reading position just above the bottom without snapping' do
    expect(@result['nearBottom']['after']).to eq(@result['nearBottom']['before'])
  end

  it 'keeps the latest messages visible after restoring a bottom position' do
    expect(@result['bottom']['scroll']).to eq(@result['bottom']['max'])
  end

  it 'restores the same message when iOS resumes a still-open page with unchanged history' do
    expect(@result['resumeReading']['after']).to eq(@result['resumeReading']['before'])
  end

  it 'keeps the latest messages visible when iOS resumes a still-open page' do
    expect(@result['resumeBottom']['after']).to eq(@result['resumeBottom']['before'])
  end

  it 'ignores app-switcher reflow scroll events that arrive before iOS reports the page hidden' do
    expect(@result['beforeHidden']['after']).to eq(@result['beforeHidden']['before'])
  end
end
