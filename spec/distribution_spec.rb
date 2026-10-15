RSpec.describe 'Source distribution contract' do
  it 'boots from a source-only release, serves generated JavaScript, and runs a complete provider call' do
    Dir.mktmpdir('sapiens-release-') do |release|
      files, error, code = Contract.capture('git', 'ls-files', 'sapiens', 'web', 'prompts', 'sapiens4')
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
        expect(isolated.calls.first['prompt']).to include(File.join(release, 'prompts/examples/jarvis-notes.html'))
        script = File.join(release, 'generated-app.js')
        File.write(script, isolated.api('GET', '/workspace/app.js'))
        out, error, code = Contract.capture('node', '--check', script)
        expect(code).to eq(0), out + error
        expect(File.exist?(File.join(release, '.git'))).to eq(false)
      ensure
        isolated.close
      end
    end
  end
end
