RSpec.describe 'Source distribution contract' do
  before(:context) do
    @folder = File.realpath(Dir.mktmpdir('sapiens source release '))
    @release = File.join(@folder, 'source')
    files, error, code = Contract.capture('git', 'ls-files', '--recurse-submodules',
      'haskell', 'sapiens/corpora/host/routine', 'macos', 'windows', 'web', 'prompts',
      'license', 'README.md', 'blindly4/license', 'blindly4/README.md', 'libs4')
    expect(code).to eq(0), error
    files.lines.map(&:strip).each do |file|
      next if file.end_with?('.py', '.swift', '.cs')
      target = File.join(@release, file)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(Contract::ROOT, file), target)
    end
    if ENV['SAPIENS_TEST_CABAL_CACHE']
      FileUtils.ln_s(File.realpath(ENV['SAPIENS_TEST_CABAL_CACHE']), File.join(@release, 'libs4/haskell/.cabal'))
    end
    @data = File.join(@folder, "existing corpora's é")
    FileUtils.mkdir_p(@data)
    File.write(File.join(@data, 'keep.txt'), 'Existing corpora data')
    @app = File.join(@release, '.build/macos/Sapiens4.app')
    if RUBY_PLATFORM.include?('darwin')
      FileUtils.mkdir_p(File.join(@app, 'Contents/Resources'))
      File.write(File.join(@app, 'Contents/Resources/obsolete-helper.py'), 'Old build artifact')
    end
    command = RUBY_PLATFORM.include?('darwin') ? ['sh', 'macos/build.sh'] : ['runghc', '-ihaskell', 'haskell/Build.hs']
    out, error, code = Contract.capture(*command, chdir: @release, timeout: 1200,
      env: {'SAPIENS_DATA_DIR' => @data})
    expect(code).to eq(0), out + error
  end

  after(:context) do
    FileUtils.remove_entry(@folder) if @folder && File.directory?(@folder)
  end

  it 'builds a signed macOS launcher for existing data without changing that data', :macos do
    skip 'macOS desktop build' unless RUBY_PLATFORM.include?('darwin')
    out, error, code = Contract.capture('plutil', '-convert', 'json', '-o', '-', File.join(@app, 'Contents/Resources/Launcher.plist'))
    expect(code).to eq(0), error
    expect(JSON.parse(out)).to include('Repository' => @release, 'DataDirectory' => @data,
      'Executable' => File.join(@release, '.build/bin/sapiens4'))
    expect(Dir.children(@data)).to eq(['keep.txt'])
    expect(File.read(File.join(@data, 'keep.txt'))).to eq('Existing corpora data')
    expect(File.exist?(File.join(@app, 'Contents/Resources/obsolete-helper.py'))).to eq(false)
    _, error, code = Contract.capture('codesign', '--verify', '--strict', @app)
    expect(code).to eq(0), error
  end

  it 'boots from a source-only release and completes work using its packaged assets' do
    isolated = Host.new(repo: @release)
    begin
      state = isolated.state
      id = isolated.submit(state['main_agent_id'], 'Hello from an installed release')
      expect(isolated.turn(id)['output']).to eq('Contract test reply')
      example = isolated.calls.first['prompt'][/read the worked example at (.*?)\. It demonstrates/m, 1]
      expect(example).not_to be_nil
      expect(File.identical?(example, File.join(@release, 'prompts/examples/jarvis-notes.html'))).to eq(true)
      %w[/workspace/ /workspace/app.js /workspace/guest.js /sw.js /remote-vendor.js /workspace/styles.css].each do |path|
        status, body = isolated.request('GET', path)
        expect(status).to eq(200)
        expect(body).not_to be_empty
      end
      expect(isolated.request('GET', '/libs4/package.json').first).to eq(404)
      expect(isolated.request('GET', '/libs4/.git').first).to eq(404)
      expect(File.exist?(File.join(@release, '.git'))).to eq(false)
    ensure
      isolated.close
    end
  end
end
