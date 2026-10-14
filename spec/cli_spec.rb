require_relative 'support/http_peer'

RSpec.describe 'CLI process contracts' do
  before do
    @state = {'agents' => [
      {'id' => 'chief-id', 'name' => 'Chief', 'role' => 'Head', 'face' => '◕ᵕ◕', 'retired' => false},
      {'id' => 'other-id', 'name' => 'Researcher', 'role' => 'Research', 'face' => '^‿^', 'retired' => true}],
      'main_agent_id' => 'chief-id', 'provider' => 'codex', 'computer' => {'built' => true},
      'turns' => [{'id' => 'turn1', 'agent' => 'chief-id', 'status' => 'done', 'input' => 'Question',
        'output' => 'Answer', 'created' => '2026-10-01T00:00:00Z', 'error' => nil}], 'workloads' => []}
    @peer = HTTPPeer.new do |request|
      if request.request_method == 'POST'
        [200, {id: 'turn1', agent: 'chief-id', status: 'queued'}]
      elsif request.path == '/api/state'
        [200, @state]
      elsif request.path == '/api/health'
        [200, {status: 'ok'}]
      elsif request.path.end_with?('/tasks')
        [200, {tasks: [{id: 'work1', title: 'Real objective', state: 'Completed', owner: 'chief-id',
          body: "objective: Real objective\n", result: 'Evidence', error: nil}]}]
      else
        [200, {path: '/fixture/Notes.html', content: '<script>bad()</script><p>Good &amp; saved</p>'}]
      end
    end
  end
  after { @peer.close }

  def cli(*args, input: '', timeout: 10)
    Contract.capture(Contract::PYTHON, File.join(Contract::ROOT, 'sapiens4'), '--url', @peer.url, *args,
      input: input, timeout: timeout, env: {'NO_COLOR' => '1', 'PYTHONUTF8' => '1'})
  end
  def writes; @peer.requests.select { |r| r[:method] == 'POST' }; end

  it 'reads live projections, filters retired agents and renders safe human history and memo' do
    text, _, code = cli('status', '--format', 'json')
    expect(code).to eq(0)
    expect(JSON.parse(text)['data']).to include('active_sapis' => 1, 'retired_sapis' => 1)
    expect(JSON.parse(cli('sapi', 'list', '--format', 'json').first)['data']['sapis'].size).to eq(1)
    expect(cli('history', '--limit', '1').first).to include('You: Question', 'Chief: Answer')
    expect(cli('memo', 'show').first).to include('Good & saved')
    expect(cli('memo', 'show').first).not_to include('<script>', 'bad()')
    expect(cli('task', 'show', 'work1', '--sapi', 'all', '--format', 'yaml').first).to eq("objective: Real objective\n")
    expect(writes).to be_empty
  end

  it 'submits a clarification exactly once and prints one JSON result while waiting' do
    text, error, code = cli('chat', 'My answer 😎', '--workload', 'work1', '--wait', '--format', 'json')
    expect(code).to eq(0)
    expect(text.lines.size).to eq(1)
    expect(JSON.parse(text)['data']['output']).to eq('Answer')
    expect(text + error).not_to include("\e")
    expect(writes.size).to eq(1)
    expect(writes.first).to include(path: '/api/agents/chief-id/messages', local: '1')
    expect(JSON.parse(writes.first[:body])).to eq('text' => 'My answer 😎', 'flow' => 'chat', 'workload' => 'work1')
  end

  {'WaitingForAdmin' => 5, 'Failed' => 1, 'Completed' => 0}.each do |state, exit_code|
    it "observes #{state} on the delegated workload rather than its completed origin turn" do
      @state['workloads'] = [{id: 'work1', origin: {call: 'turn1'}, callId: 'child', owner: 'other-id', state: state,
        output: 'Which release?', error: state == 'Failed' ? 'Provider failed' : nil}]
      text, _, code = cli('conversation', 'watch', 'turn1', '--format', 'json')
      expect(code).to eq(exit_code)
      expect(JSON.parse(text)['data']).to include('workload' => 'work1', 'state' => state)
      expect(writes).to be_empty
    end
  end

  it 'streams state changes and detaches on interrupt without cancelling server work', :posix do
    skip 'POSIX signal contract' if Gem.win_platform?
    @state['turns'].first['status'] = 'running'
    process = Contract::Child.new(Contract::PYTHON, '-u', File.join(Contract::ROOT, 'sapiens4'),
      '--url', @peer.url, 'conversation', 'watch', 'turn1', '--format', 'jsonl')
    Contract.wait { process.stdout.include?('running') }
    @state['turns'].first['status'] = 'done'
    text, _, code = process.finish(5)
    expect(code).to eq(0)
    expect(text.lines.map { |line| JSON.parse(line)['event'] }).to eq(%w[snapshot state_changed])
    process.close
    process = Contract::Child.new(Contract::PYTHON, '-u', File.join(Contract::ROOT, 'sapiens4'), '--url', @peer.url, 'status', '--watch', '--format', 'jsonl')
    Contract.wait { process.stdout.include?('snapshot') }
    process.signal('INT')
    text, _, code = process.finish(5)
    expect(code).to eq(130)
    expect(JSON.parse(text.lines.last)['error']['code']).to eq('DETACHED')
    expect(writes).to be_empty
  ensure
    process.close if process
  end

  [
    %w[sapi create], %w[status --format jsonl], %w[status --timeout nan], %w[history --limit 0],
    %w[memo show --format yaml], %w[chat --typo], %w[status --wait], %w[sapi list --tab past]
  ].each do |args|
    it "rejects #{args.join(' ')} without contacting the host" do
      expect(cli(*args).last).to eq(2)
      expect(@peer.requests).to be_empty
    end
  end

  ['https://example.com', 'http://127.0.0.1:80@evil.test:80', 'http://127.0.0.1:80/path', 'http://127.0.0.1:99999'].each do |url|
    it "refuses unsafe host URL #{url}" do
      _, _, code = cli('status', '--url', url, '--format', 'json')
      expect(code).not_to eq(0)
      expect(@peer.requests).to be_empty
    end
  end

  {
    'host rejection' => [409, {error: 'Rejected by host'}, {}, 'HTTP_409'],
    'invalid response' => [200, 'not json', {}, 'INVALID_RESPONSE'],
    'redirect' => [302, '', {'Location' => '/api/state'}, 'HTTP_302']
  }.each do |behavior, response|
    it "never resubmits a write after #{behavior}" do
      previous = @peer.handler
      @peer.handler = ->(request) { request.request_method == 'POST' ? response.take(3) : previous.call(request) }
      text, _, code = cli('chat', 'Exactly once', '--format', 'json')
      expect(code).not_to eq(0)
      expect(JSON.parse(text)['error']['code']).to eq(response.last)
      expect(writes.size).to eq(1)
    end
  end

  it 'preserves literal input and shell context while history and navigation remain read-only' do
    message = "Don't change  'quotes' or --format=json or @Researcher."
    text, _, code = cli('shell', input: "call @Chief\n#{message}\nchat -1\ncorpora\ncall @Researcher\nchat\ncorpora\nexit\n")
    expect(code).to eq(0)
    expect(text).to include('sapiens4 ⌘ @Chief >', 'No conversations yet.', 'Answer')
    expect(writes.size).to eq(1)
    expect(JSON.parse(writes.first[:body])['text']).to eq(message)
  end

  it 'sanitizes terminal control sequences and honors plain output through the actual entrypoint' do
    @state['agents'].first['name'] = "\e[2JChief\e]0;evil\a"
    text, error, code = cli('sapi', 'list', '--plain')
    expect(code).to eq(0)
    expect(text).to include('Chief')
    expect(text + error).not_to include("\e", 'evil')
    expect(text.ascii_only?).to eq(true)
  end

  it 'reports a timed-out submission as uncertain without sending it again' do
    previous = @peer.handler
    @peer.handler = lambda do |request|
      sleep 5.5 if request.request_method == 'POST'
      previous.call(request)
    end
    text, _, code = cli('chat', 'Once only', '--format', 'json')
    expect(code).to eq(1)
    expect(JSON.parse(text)['error']).to include('code' => 'SUBMISSION_UNCERTAIN')
    expect(writes.size).to eq(1)
  end

  it 'reports an offline host without trying to start a service' do
    @peer.close
    text, _, code = cli('status', '--format', 'json')
    expect(code).to eq(3)
    expect(JSON.parse(text)['error']['code']).to eq('HOST_UNAVAILABLE')
    expect(@peer.requests).to be_empty
  end

  it 'restores terminal drafts and scoped history, completes live names, and submits only intentional messages' do
    skip 'requires a POSIX terminal' if Gem.win_platform?
    require 'pty'
    require 'io/console'
    PTY.open do |terminal, slave|
      slave.winsize = [24, 100]
      pid = Process.spawn({'TERM' => 'xterm-256color', 'PYTHONUTF8' => '1', 'PROMPT_TOOLKIT_NO_CPR' => '1'},
        Contract::PYTHON, File.join(Contract::ROOT, 'sapiens4'), 'shell', '--url', @peer.url,
        in: slave, out: slave, err: slave, pgroup: true)
      slave.close
      output = +''
      reader = Thread.new do
        loop { output << terminal.readpartial(65536) }
      rescue EOFError, IOError, Errno::EIO
      end
      exchange = lambda do |keys, *expected|
        output.clear
        terminal.write(keys) if keys
        Contract.wait(timeout: 8, description: "terminal output #{expected.inspect}: #{output}") do
          clean = output.dup.force_encoding('UTF-8').scrub.gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '')
          expected.all? { |value| clean.include?(value) }
        end
      end
      exchange.call(nil, 'sapiens4 ⌘ corpora >')
      exchange.call("show\n", 'Chief · Head', 'sapiens4 ⌘ corpora >')
      exchange.call("status\n", 'corpora | online', 'sapiens4 ⌘ corpora >')
      exchange.call("\e[A\e[A\n", 'Chief · Head', 'sapiens4 ⌘ corpora >')
      exchange.call("stat\eOA\eOBus\n", 'corpora | online', 'sapiens4 ⌘ corpora >')
      exchange.call("call @Ch\t\n", 'sapiens4 ⌘ @Chief >')
      exchange.call("Review this once.\n", 'Answer', 'sapiens4 ⌘ @Chief >')
      exchange.call("\e[A\e[B\nchat -1\n", 'Chief: Answer', 'sapiens4 ⌘ @Chief >')
      exchange.call("corpora\n", 'sapiens4 ⌘ corpora >')
      exchange.call("\e[A\n", 'sapiens4 ⌘ @Chief >')
      exchange.call("\e[A\e[A\n", 'Chief: Answer', 'sapiens4 ⌘ @Chief >')
      exchange.call("exit\n", 'Detached.')
      _, status = Timeout.timeout(5) { Process.waitpid2(pid) }
      pid = nil
      expect(status.exitstatus).to eq(0)
      expect(writes.size).to eq(1)
      expect(JSON.parse(writes.first[:body])).to eq('text' => 'Review this once.', 'flow' => 'chat')
    ensure
      if pid
        Process.kill('KILL', pid)
        Process.waitpid(pid)
      end
      reader.join if reader
    end
  end
end
