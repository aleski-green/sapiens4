RSpec.describe 'Remote app installation guidance' do
  {
    'ios' => ['IPHONE & IPAD', 'Add to Home Screen', 'Safari', 'Open as Web App'],
    'android' => ['ANDROID', 'Add to Home Screen', 'Chrome', 'Install'],
    'mac' => ['MAC', 'Install Sapiens4', 'Add to Dock', 'Chrome'],
    'windows' => ['WINDOWS', 'Install Sapiens4', 'Chrome or Edge', 'Start menu']
  }.each do |platform, (title, action, *instructions)|
    it "explains how to install on #{platform} and hides the guide in standalone mode" do
      probe = File.join(Contract::ROOT, 'spec/support/install_probe.cjs')
      out, error, code = Contract.capture('node', probe, "/#{platform}")
      expect(code).to eq(0), error
      result = JSON.parse(out)
      expect(result['title']).to eq("SAPIENS4 FOR #{title}")
      expect(result['entry']).to eq(action)
      instructions.each { |text| expect(result['instructions']).to include(text) }
      out, error, code = Contract.capture('node', probe, "/#{platform}", 'standalone')
      expect(code).to eq(0), error
      expect(JSON.parse(out)).to eq('entry' => nil, 'title' => nil, 'instructions' => nil)
    end
  end
end
