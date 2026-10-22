require_relative 'support/updater_environment'
require_relative 'support/http_peer'

RSpec.describe 'Desktop updater process contracts', :macos do
  before do
    skip 'macOS release-manager integration' unless RUBY_PLATFORM.include?('darwin')
    @installation = UpdaterEnvironment.new
  end
  after { @installation.close if @installation }

  def installation; @installation; end

  it 'checks for an update without changing active release or user data' do
    File.write(File.join(installation.data, 'keep.txt'), 'Saved user work')
    _, error, code = installation.run('check')
    expect(code).to eq(0), error
    expect(installation.status).to include('phase' => 'available', 'sha' => installation.revision)
    expect(installation.current).to eq(installation.old)
    expect(File.read(File.join(installation.data, 'keep.txt'))).to eq('Saved user work')
  end

  it 'rejects malformed upstream revisions before preparing a release' do
    installation.configure(revision: 'not-a-revision')
    expect(installation.run('update').last).to eq(1)
    expect(installation.status['message']).to include('valid main revision')
    expect(installation.current).to eq(installation.old)
    expect(Dir[File.join(installation.home, 'releases', '*')].size).to eq(1)
  end

  [:model, :compiler, :sdk, :schema].each do |failure|
    it "preserves the running release and data when #{failure} preparation fails" do
      installation.start
      before = Contract.http(installation.url + '/api/health', 'GET')[1]
      File.write(File.join(installation.data, 'keep.txt'), 'Saved user work')
      installation.host.configure(fail: true) if failure == :model
      installation.configure(build_failure: true) if failure == :compiler
      installation.configure(sdk_failure: true) if failure == :sdk
      installation.configure(schema_failure: true) if failure == :schema
      _, _, code = installation.run('update')
      expect(code).to eq(1)
      expect(installation.status['message']).to include('Fixture Rust compiler source error') if failure == :compiler
      expect(installation.status['message']).to include('Fixture schema failed') if failure == :schema
      expect(installation.current).to eq(installation.old)
      expect(Contract.http(installation.url + '/api/health', 'GET')[1]).to eq(before)
      expect(File.read(File.join(installation.data, 'keep.txt'))).to eq('Saved user work')
      expect(File.exist?(File.join(installation.home, 'transaction.json'))).to eq(false)
    end
  end

  it 'holds HTTP work behind the activation barrier and then starts the real service' do
    activation = installation.start(activate: false)
    expect(Contract.http(installation.url + '/api/state', 'GET').first).to eq(503)
    expect(Contract.http(installation.url + '/api/agents', 'POST', {name: 'TooSoon', role: 'Research'}).first).to eq(503)
    File.write(activation, '')
    Contract.wait { Contract.http(installation.url + '/api/health', 'GET')[1]['desktop_active'] }
    expect(Contract.http(installation.url + '/api/state', 'GET')[1]['agents'].map { |a| a['name'] }).to eq(['ChiefSapi'])
  end

  it 'backs up a stopped installation and activates the candidate only after committing the new release' do
    installation.start
    state = Contract.http(installation.url + '/api/state', 'GET')[1]
    File.write(File.join(installation.data, 'artifact.txt'), 'Saved result')
    _, error, code = installation.run('update')
    expect(code).to eq(0), error
    expect(installation.current['sha']).to eq(installation.revision)
    expect(installation.status['phase']).to eq('current')
    Contract.wait { Contract.http(installation.url + '/api/health', 'GET')[1]['desktop_active'] }
    expect(Contract.http(installation.url + '/api/state', 'GET')[1]['corpora']).to eq(state['corpora'])
    expect(File.read(File.join(installation.data, 'artifact.txt'))).to eq('Saved result')
    backups = Dir[File.join(installation.home, 'backups', '*', 'artifact.txt')]
    expect(backups.size).to eq(1)
    expect(File.read(backups.first)).to eq('Saved result')
    expect(File.exist?(File.join(installation.home, 'transaction.json'))).to eq(false)
  end

  it 'waits for active work to finish before switching releases and preserves its result' do
    installation.host.configure(rules: {'Assessing' => {block: true}})
    installation.start
    state = Contract.http(installation.url + '/api/state', 'GET')[1]
    turn = Contract.http(installation.url + "/api/agents/#{state['main_agent_id']}/messages", 'POST', {text: 'Finish before updating'})[1]
    Contract.wait { installation.host.calls.any? }
    update = Contract::Child.new(Contract::PYTHON, File.join(Contract::ROOT, 'macos/updater.py'),
      '--home', installation.home, 'update', env: installation.environment)
    Contract.wait { File.exist?(File.join(installation.home, 'status.json')) && installation.status['phase'] == 'waiting' }
    expect(installation.current).to eq(installation.old)
    expect(Contract.http(installation.url + '/api/state', 'GET')[1]['turns'].find { |t| t['id'] == turn['id'] }['status']).to eq('running')
    installation.host.release
    _, error, code = update.finish(40)
    expect(code).to eq(0), error
    expect(installation.current['sha']).to eq(installation.revision)
    Contract.wait { Contract.http(installation.url + '/api/health', 'GET')[1]['desktop_active'] }
    result = Contract.http(installation.url + '/api/state', 'GET')[1]['turns'].find { |t| t['id'] == turn['id'] }
    expect(result).to include('status' => 'done', 'output' => 'Contract test reply')
  ensure
    installation.host.release
    update.close if update
  end

  it 'refuses to replace another application listening on its configured port' do
    peer = HTTPPeer.new { [200, {status: 'ok'}, {'Server' => 'Another application'}] }
    path = File.join(installation.home, 'config.json')
    Contract.atomic_json(path, JSON.parse(File.read(path)).merge('port' => URI(peer.url).port))
    expect(installation.run('update').last).to eq(1)
    expect(installation.status['message']).to include('another application')
    expect(installation.current).to eq(installation.old)
    expect(Contract.http(peer.url + '/api/health', 'GET')[1]).to eq('status' => 'ok')
  ensure
    peer.close if peer
  end

  it 'cleans obsolete build caches on launch without deleting binaries, user files or symlink targets' do
    release = installation.old['root']
    cache = File.join(release, '.build/macos/module-cache')
    binary = File.join(release, 'blindly4/.build/release/blindly4')
    outside = File.join(installation.data, 'saved-cache')
    FileUtils.mkdir_p([cache, File.dirname(binary), outside])
    File.write(File.join(cache, 'temporary.pcm'), 'Build cache')
    File.write(binary, 'Retain installed binary')
    File.chmod(0755, binary)
    File.write(File.join(outside, 'keep.o'), 'User artifact')
    link = File.join(release, 'blindly4/.build/debug')
    File.symlink(outside, link)
    2.times do
      _, error, code = installation.run('launch')
      expect(code).to eq(0), error
      expect(File.exist?(cache)).to eq(false)
      expect(File.read(binary)).to eq('Retain installed binary')
      expect(File.stat(binary).mode & 0777).to eq(0755)
      expect(File.symlink?(link)).to eq(true)
      expect(File.read(File.join(outside, 'keep.o'))).to eq('User artifact')
    end
  end

  [false, true].each do |committed|
    it "recovers a #{committed ? 'committed' : 'pre-commit'} update journal without overwriting newer work on subsequent launches" do
      backup = File.join(installation.home, 'backups', 'before-update')
      FileUtils.mkdir_p(backup)
      File.write(File.join(backup, 'artifact.txt'), 'Old saved work')
      File.write(File.join(installation.data, 'artifact.txt'), 'New saved work')
      activation = File.join(installation.home, 'activate-crashed')
      Contract.atomic_json(File.join(installation.home, 'transaction.json'), {
        old: installation.old, new: installation.old, backup: backup, committed: committed, activation: activation})
      _, error, code = installation.run('launch')
      expect(code).to eq(0), error
      expect(File.read(File.join(installation.data, 'artifact.txt'))).to eq(committed ? 'New saved work' : 'Old saved work')
      expect(File.exist?(File.join(installation.home, 'transaction.json'))).to eq(false)
      File.write(File.join(installation.data, 'artifact.txt'), 'Completed after recovery')
      expect(installation.run('launch').last).to eq(0)
      expect(File.read(File.join(installation.data, 'artifact.txt'))).to eq('Completed after recovery')
      expect(File.exist?(activation)).to eq(true) if committed
    end
  end

  [:invalid_candidate, :corrupt_stage, :post_exchange].each do |failure|
    it "preserves the installed desktop on #{failure} and leaves installation retryable" do
      installed, = installation.desktop(candidate_valid: failure != :invalid_candidate)
      installation.configure(corrupt_stage: true) if failure == :corrupt_stage
      installation.configure(invalid_signature: 'Installed.app') if failure == :post_exchange
      original = File.binread(File.join(installed, 'Contents/Info.plist'))
      expect(installation.run('update').last).to eq(1)
      expect(File.binread(File.join(installed, 'Contents/Info.plist'))).to eq(original)
      expect(installation.current['desktop_revision']).to be_nil
      expect(installation.run('check').last).to eq(0)
      expect(installation.status['phase']).to eq('available')
    end
  end
end
