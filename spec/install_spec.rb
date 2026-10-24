require_relative 'support/relay'

RSpec.describe 'Remote app installation guidance' do
  def logo_probe(scenario)
    out, error, code = Contract.capture('node', 'spec/support/logo-reload.cjs', scenario)
    expect(code).to eq(0), error
    JSON.parse(out)
  end

  it 'reloads the iOS home-screen app only after an update activates, keeping the latest draft and connection' do
    result = logo_probe('update')
    expect(result).to include('beforeActivation' => 0, 'updates' => 1, 'reloads' => 1, 'normalClicks' => 0,
      'draft' => 'Draft edited while checking', 'connection' => 'unchanged')
    expect(result['events']).to eq(%w[save check activated save reload])
    expect(result['label']).to include('Reload', 'updates')
  end

  %w[unchanged offline failed timeout no-worker].each do |scenario|
    it "reopens the complete saved iOS app when the update is #{scenario}" do
      result = logo_probe(scenario)
      expect(result).to include('reloads' => 1, 'normalClicks' => 0, 'connection' => 'unchanged')
      expect(result['draft']).to match(/draft/i)
      expect(result['events'].last(2)).to eq(%w[save reload])
    end
  end

  %w[browser android desktop].each do |scenario|
    it "keeps normal logo navigation in #{scenario}" do
      expect(logo_probe(scenario)).to include('updates' => 0, 'reloads' => 0, 'normalClicks' => 1)
    end
  end

  it 'activates a complete updated shell without waiting for backgrounded iOS clients' do
    out, error, code = Contract.capture('node', 'spec/support/shell-update.cjs')
    expect(code).to eq(0), error
    result = JSON.parse(out)
    expect(result['success']['events']).to eq(%w[download complete activate-ready])
    expect(result['success'].values_at('asset', 'offlinePage')).to eq(['new shell', 'new shell'])
    expect(result['failure']['events']).to eq(%w[download failed])
    expect(result['online'].values_at('asset', 'offlinePage')).to eq(['new shell', 'new shell'])
    expect(result['online']['events']).not_to include('network-newer-shell')
  end

  it 'serves every public shell asset advertised for offline installation with a versioned cache' do
    relay = Relay.new
    status, script = relay.request('GET', '/sw.js')
    expect(status).to eq(200)
    expect(script).to match(/sapiens-shell-[0-9a-f]{16}/)
    out, error, code = Contract.capture('node', 'spec/support/shell-update.cjs')
    expect(code).to eq(0), error
    paths = JSON.parse(out).fetch('success').fetch('assets')
    expect(paths).to include('/', '/workspace/app.js', '/corpora.js', '/corpora.css')
    paths.each do |path|
      expect(path).not_to start_with('/api/')
      expect(relay.request('GET', path).first).to eq(200), "Missing installation asset: #{path}"
    end
  ensure
    relay.close if relay
  end

  it 'redirects the previous pairing page into the workspace', :host do
    status, _, headers = host.request('GET', '/remote/')
    expect(status).to eq(302)
    expect(headers['location']).to eq(['/workspace/?pairing=local'])
    expect(host.request('GET', headers['location'].first).first).to eq(200)
  end

  def install_probe(platform, mode = 'browser')
    out, error, code = Contract.capture('node', 'spec/support/install_probe.cjs', platform, mode)
    expect(code).to eq(0), error
    JSON.parse(out)
  end

  {'ios' => ['Safari', 'Share', 'Open as Web App'],
   'ipad' => ['Safari', 'Share', 'Open as Web App'],
   'android' => ['Chrome', 'Install and create shortcut', 'Install']}.each do |platform, instructions|
    it "shows concise #{platform} instructions, chosen by the device even on an /ios link" do
      result = install_probe(platform)
      expect(result).to include('gate' => true, 'title' => 'Add to Home Screen', 'network' => 0, 'storage' => 0, 'cookie' => '')
      instructions.each { |text| expect(result['instructions']).to include(text) }
      expect(result['words']).to be <= 50
      expect(result['help']).to eq('href' => 'https://sapiens4.ai/help?q=add2homescreen', 'target' => '_blank', 'rel' => 'noopener noreferrer')
      expect(install_probe(platform, 'standalone')['gate']).to eq(false)
    end
  end

  it 'keeps the first update readable for an older cached mobile client' do
    expect(install_probe('ios', 'legacy')).to include('gate' => true, 'title' => 'Add to Home Screen', 'legacyGuideOpened' => true)
  end

  it 'offers the native Android prompt without unlocking connections in the browser' do
    expect(install_probe('android', 'prompt')).to eq('offered' => true, 'prompts' => 1, 'hiddenAfter' => true, 'gate' => true, 'prevented' => true)
  end

  it 'does not require installation in desktop browsers' do
    expect(install_probe('linux')['gate']).to eq(false)
  end
end
