RSpec.describe 'Workspace remote client regression contracts' do
  def browser_probe(file, scenario)
    out, error, code = Contract.capture('node', "spec/support/#{file}.cjs", scenario)
    expect(code).to eq(0), out + error
    JSON.parse(out)
  end

  it 'loads note images through the selected corpora connection' do
    expect(browser_probe('remote-browser', 'notes')).to eq('src' => 'blob:note',
      'requested' => ['/api/agents/chief/notes?image=photo.png'], 'released' => ['blob:note'])
  end

  it 'captures actual QR images and releases cameras on success, cancellation and disposal' do
    result = browser_probe('remote-browser', 'scanner')
    expect(result['unavailable']).to include('Camera unavailable')
    expect(result['upload']).to eq(result['expected'])
    expect(result['camera']).to eq(result['expected'])
    expect(result).to include('cancelledStops' => 1, 'cameraStopped' => true, 'urlsRevoked' => 1, 'pairs' => 2, 'disposedStops' => 4)
    expect(result['largeImage']).to include('10 MB')
    expect(result['largePayload']).to include('Use the QR')
  end

  it 'preserves encrypted requests, QR validation, persisted identity and interruption safety in the current transport' do
    result = browser_probe('remote-browser', 'transport')
    expect(result['invalid']).to eq('errors' => 5, 'connections' => 0)
    expect(result['decodeErrors']).to eq([true, true, true])
    expect(result['confirmation']).to eq('CwnX · eCGC')
    expect(result).to include('unapproved' => 0, 'encrypted' => true, 'sent' => 202, 'image' => [1, 2, 3],
      'badResponses' => [true, true], 'replayed' => false, 'browserStorage' => 0, 'corruptRemaining' => 0)
    expect(result['message']).to eq('text' => 'Private command')
    expect(result['saved']).to include('secret' => nil, 'sameKey' => true)
    expect(result['resume']).to eq('op' => 'resume', 'key' => true)
    expect(result['identityError']).to include('identity changed')
    expect(result['identityKept']).to eq(result['saved']['corpora'])
    expect(result['corrupt']).to include('keys are invalid')
    expect(result['interrupted']).to include('unreachable')
  end

  it 'keeps local, saved and file-based relay setup in the workspace pairing dialog' do
    result = browser_probe('corpora-browser', 'pairing-setup')
    expect(result).to include('local' => true, 'saved' => true, 'noCodeDisabled' => true,
      'code' => 'CwnX · eCGC', 'expiredQR' => false, 'error' => 'Relay unavailable')
    expect(result['imported']).to eq('relay' => 'https://relay.example', 'enabled' => true, 'writes' => 0)
    expect(result['invalid']).to eq('relay' => '', 'token' => '', 'disabled' => true)
    expect(result['invitation']).to include('download' => 'data:image/png;base64,AAAA', 'link' => 'https://relay.example/', 'expiry' => true, 'token' => '')
    expect(result['writes']).to include({'path' => '/pair', 'data' => {'local' => true}},
      {'path' => '/pair', 'data' => {'saved' => true}}, {'path' => '/approve', 'data' => {'peer' => 'phone'}})
  end
end
