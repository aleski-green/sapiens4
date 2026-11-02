RSpec.describe 'Linux headless workspace browsers', :host do
  %w[chromium firefox].product([1, 2]).each do |browser, scale|
    it "sends and restores a Unicode conversation in #{browser} at #{scale}x scale" do
      skip 'Pinned Linux browser binaries required' unless ENV['SAPIENS_TEST_HEADLESS_BROWSERS'] == '1'
      message = 'Compare café, العربية and 🐧'
      output, error, status = Contract.capture('node', File.join(Contract::ROOT, 'spec/support/HeadlessBrowser.cjs'),
        browser, host.url + '/workspace/', message, scale.to_s, timeout: 60,
        env: {'PLAYWRIGHT_BROWSERS_PATH' => File.join(Contract::ROOT, 'submodules/libs4/.cache/playwright'),
          'DISPLAY' => ENV['SAPIENS_TEST_HEADED'] == '1' ? ENV['DISPLAY'] : nil})
      expect(status).to eq(0), output + error
      result = JSON.parse(output)
      expect(result).to include('reply' => 'Contract test reply', 'restored' => 'Contract test reply', 'draft' => '')
      expect(result.fetch('version')).not_to be_empty
      expect(host.state.fetch('turns')).to include(a_hash_including('input' => message, 'status' => 'done'))
      expect(host.calls.size).to eq(1)
    end
  end
end
