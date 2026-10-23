RSpec.describe 'Source distribution contract' do
  it 'fetches the pinned browser bundle when an older macOS updater invokes the new desktop build', :macos do
    skip 'macOS desktop build entrypoint' unless RUBY_PLATFORM.include?('darwin')
    Dir.mktmpdir('sapiens legacy update ') do |folder|
      release = File.join(folder, 'release')
      out, error, code = Contract.capture('git', 'clone', '--quiet', '--shared', Contract::ROOT, release)
      expect(code).to eq(0), out + error
      _, error, code = Contract.capture('git', '-C', release, 'config', 'submodule.libs4.url', File.join(Contract::ROOT, 'libs4'))
      expect(code).to eq(0), error
      bundle = File.join(release, 'libs4/web/remote-vendor.js')
      expect(File.exist?(bundle)).to eq(false)
      tools = File.join(folder, 'tools')
      FileUtils.mkdir_p(tools)
      compiler = File.join(tools, 'xcrun')
      File.write(compiler, "#!/bin/sh\necho 'Fixture compiler reached' >&2\nexit 42\n")
      File.chmod(0755, compiler)
      _, error, code = Contract.capture('sh', 'macos/build.sh', chdir: release,
        env: {'PATH' => tools + File::PATH_SEPARATOR + ENV.fetch('PATH'), 'GIT_ALLOW_PROTOCOL' => 'file'})
      expect(code).to eq(42), error
      expect(error).to include('Fixture compiler reached')
      expect(File.binread(bundle)).to eq(File.binread(File.join(Contract::ROOT, 'libs4/web/remote-vendor.js')))
    end
  end

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
