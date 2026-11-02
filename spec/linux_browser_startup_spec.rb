require_relative 'support/http_peer'

RSpec.describe 'Linux browser startup stability' do
  %w[chromium firefox].each do |engine|
    it "starts and closes #{engine} repeatedly without a retry" do
      skip 'Isolated browser stress session required' unless ENV['SAPIENS_TEST_BROWSER_STRESS'] == '1'
      runs = Integer(ENV.fetch('SAPIENS_TEST_BROWSER_RUNS', '20'))
      expect(runs).to be_between(1, 100)
      pages = HTTPPeer.new { |_| [200, '<title>Startup fixture</title>', {'Content-Type' => 'text/html'}] }
      runs.times do |index|
        browser = Contract::Child.new('node', File.join(Contract::ROOT, 'spec/support/DesktopBrowser.cjs'), engine, pages.url,
          env: {'PLAYWRIGHT_BROWSERS_PATH' => File.join(Contract::ROOT, 'submodules/libs4/.cache/playwright')})
        Contract.wait(description: "#{engine} launch #{index + 1}") do
          raise browser.stderr unless browser.stderr.empty?
          browser.stdout.include?('READY ')
        end
        browser.input.close
        output, error, status = browser.finish(20)
        expect(status).to eq(0), "Launch #{index + 1}: #{output}#{error}"
        expect(output).to match(/READY \d+ \S+/)
      ensure
        browser&.close
      end
      expect(pages.requests.count { |request| request[:path] == '/' }).to eq(runs)
    ensure
      pages&.close
    end
  end
end
