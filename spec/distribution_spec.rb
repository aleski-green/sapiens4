RSpec.describe 'Source distribution contract' do
  it 'boots from a source-only release, serves generated JavaScript, and runs a complete provider call' do
    Dir.mktmpdir('sapiens-release-') do |release|
      files, error, code = Contract.capture('git', 'ls-files', '--recurse-submodules', 'sapiens', 'web', 'prompts', 'sapiens4', 'libs4')
      expect(code).to eq(0), error
      files.lines.map(&:strip).each do |file|
        target = File.join(release, file)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(Contract::ROOT, file), target)
      end
      isolated = Host.new(repo: release)
      begin
        state = isolated.state
        id = isolated.submit(state['main_agent_id'], 'Hello from an installed release')
        expect(isolated.turn(id)['output']).to eq('Contract test reply')
        example = isolated.calls.first['prompt'][/read the worked example at (.*?)\. It demonstrates/m, 1]
        expect(example).not_to be_nil
        expect(File.identical?(example, File.join(release, 'prompts/examples/jarvis-notes.html'))).to eq(true)
        script = File.join(release, 'generated-app.js')
        File.write(script, isolated.api('GET', '/workspace/app.js'))
        out, error, code = Contract.capture('node', '--check', script)
        expect(code).to eq(0), out + error
        vendor = isolated.api('GET', '/remote-vendor.js')
        expect(vendor).to eq(File.binread(File.join(Contract::ROOT, 'libs4/web/remote-vendor.js')))
        expect(isolated.request('GET', '/libs4/package.json').first).to eq(404)
        expect(isolated.request('GET', '/libs4/.git').first).to eq(404)
        expect(File.exist?(File.join(release, '.git'))).to eq(false)
      ensure
        isolated.close
      end
    end
  end
end
