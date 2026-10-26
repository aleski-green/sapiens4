RSpec.describe 'Source distribution contract' do
  it 'builds a signed macOS launcher for existing data without changing that data', :macos do
    skip 'macOS desktop build' unless RUBY_PLATFORM.include?('darwin')
    Dir.mktmpdir('sapiens desktop ') do |folder|
      folder = File.realpath(folder)
      release = File.join(folder, 'source')
      files, error, code = Contract.capture('git', 'ls-files', '--recurse-submodules',
        'macos', 'sapiens', 'web', 'license', 'README.md', 'blindly4/license', 'blindly4/README.md', 'libs4')
      expect(code).to eq(0), error
      files.lines.map(&:strip).each do |file|
        target = File.join(release, file)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(Contract::ROOT, file), target)
      end
      FileUtils.mkdir_p(File.join(release, 'libs4/web'))
      FileUtils.cp(File.join(Contract::ROOT, 'libs4/web/remote-vendor.js'), File.join(release, 'libs4/web'))
      data = File.join(folder, "existing corpora's é")
      FileUtils.mkdir_p(data)
      File.write(File.join(data, 'keep.txt'), 'Existing corpora data')
      app = File.join(release, '.build/macos/Sapiens4.app')
      FileUtils.mkdir_p(File.join(app, 'Contents/Resources'))
      File.write(File.join(app, 'Contents/Resources/obsolete-helper.py'), 'Old build artifact')
      out, error, code = Contract.capture('sh', 'macos/build.sh', chdir: release, timeout: 600,
        env: {'SAPIENS_PYTHON' => Contract::PYTHON, 'SAPIENS_DATA_DIR' => data})
      expect(code).to eq(0), out + error
      out, error, code = Contract.capture('plutil', '-convert', 'json', '-o', '-', File.join(app, 'Contents/Resources/Launcher.plist'))
      expect(code).to eq(0), error
      expect(JSON.parse(out)).to include('Repository' => release, 'DataDirectory' => data, 'Python' => Contract::PYTHON)
      expect(Dir.children(data)).to eq(['keep.txt'])
      expect(File.read(File.join(data, 'keep.txt'))).to eq('Existing corpora data')
      expect(File.exist?(File.join(app, 'Contents/Resources/obsolete-helper.py'))).to eq(false)
      _, error, code = Contract.capture('codesign', '--verify', '--strict', app)
      expect(code).to eq(0), error
    end
  end

  it 'boots from a source-only release and completes work using its packaged assets' do
    Dir.mktmpdir('sapiens-release-') do |release|
      files, error, code = Contract.capture('git', 'ls-files', '--recurse-submodules', 'sapiens', 'web', 'prompts', 'libs4')
      expect(code).to eq(0), error
      files.lines.map(&:strip).each do |file|
        target = File.join(release, file)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(Contract::ROOT, file), target)
      end
      out, error, code = Contract.capture(Contract::PYTHON, 'sapiens/build.py', chdir: release, timeout: 600)
      expect(code).to eq(0), out + error
      out, error, code = Contract.capture(Contract::PYTHON, 'web/shell/build.py', chdir: release, timeout: 600)
      expect(code).to eq(0), out + error
      isolated = Host.new(repo: release)
      begin
        state = isolated.state
        id = isolated.submit(state['main_agent_id'], 'Hello from an installed release')
        expect(isolated.turn(id)['output']).to eq('Contract test reply')
        example = isolated.calls.first['prompt'][/read the worked example at (.*?)\. It demonstrates/m, 1]
        expect(example).not_to be_nil
        expect(File.identical?(example, File.join(release, 'prompts/examples/jarvis-notes.html'))).to eq(true)
        %w[/workspace/ /workspace/app.js /workspace/guest.js /sw.js /remote-vendor.js /workspace/styles.css].each do |path|
          status, body = isolated.request('GET', path)
          expect(status).to eq(200)
          expect(body).not_to be_empty
        end
        expect(isolated.request('GET', '/libs4/package.json').first).to eq(404)
        expect(isolated.request('GET', '/libs4/.git').first).to eq(404)
        expect(File.exist?(File.join(release, '.git'))).to eq(false)
      ensure
        isolated.close
      end
    end
  end
end
