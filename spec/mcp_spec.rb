require 'json'

RSpec.describe 'MCP server for other AI tools', :host do
  def session(*requests)
    lines = [{jsonrpc: '2.0', id: 0, method: 'initialize', params: {protocolVersion: '2025-11-25', capabilities: {}, clientInfo: {name: 'spec', version: '1'}}},
      {jsonrpc: '2.0', method: 'notifications/initialized'}]
    requests.each_with_index { |(method, params), index| lines << {jsonrpc: '2.0', id: index + 1, method: method, params: params} }
    out, error, code = Contract.capture(Contract::BINARY, 'mcp', '--url', host.url, input: lines.map { |line| JSON.generate(line) + "\n" }.join)
    expect(code).to eq(0), error
    replies = out.lines.map { |line| JSON.parse(line) }
    expect(replies.map { |reply| reply['id'] }).to eq((0..requests.size).to_a)
    expect(replies.first.dig('result', 'protocolVersion')).to eq('2025-11-25')
    replies.drop(1).map { |reply| reply.fetch('result') }
  end

  def tool(name, **arguments)
    ['tools/call', {name: name, arguments: arguments}]
  end

  def body(result)
    JSON.parse(result.dig('content', 0, 'text'))
  end

  let(:corpora) { host.state.dig('corpora', 'id') }

  it 'lets another AI find the corpora and its Sapis, hand a Sapi work and read the reply' do
    tools, listed, sapis, sent, unknown = session(['tools/list', {}], tool('corpora'), tool('sapis', corpora: corpora),
      tool('send', corpora: corpora, sapi: chief, text: 'Run the regression tests.'), tool('send', corpora: corpora, sapi: 'no-such-sapi', text: 'Hi'))
    expect(tools['tools'].map { |item| item['name'] }).to eq(%w[corpora sapis chat send lifecycle])
    expect(body(listed)).to include(include('id' => corpora, 'location' => 'Local'))
    expect(body(sapis)).to include(include('id' => chief, 'chief' => true, 'busy' => false, 'tabs' => be_an(Array)))
    expect(sent['isError']).to be(false)
    turn = host.turn(body(sent).fetch('id'))
    expect(unknown['isError']).to be(true)
    chat, = session(tool('chat', corpora: corpora, sapi: chief, limit: 1))
    expect(body(chat).map { |row| row.slice('id', 'input', 'status') }).to eq([turn.slice('id', 'input', 'status')])
  end

  it 'lets another AI pause a corpora, which refuses new work until it is activated again' do
    paused, refused, active, sent = session(tool('lifecycle', corpora: corpora, action: 'pause'), tool('send', corpora: corpora, sapi: chief, text: 'Hi'),
      tool('lifecycle', corpora: corpora, action: 'activate'), tool('send', corpora: corpora, sapi: chief, text: 'Hi again'))
    expect(body(paused)).to include('status' => 'paused')
    expect(refused).to include('isError' => true)
    expect(refused.dig('content', 0, 'text')).to include('Activate this corpora')
    expect(body(active)).to include('status' => 'active')
    host.turn(body(sent).fetch('id'))
  end

  it 'reports a host that is not running as a tool error instead of crashing' do
    out, error, code = Contract.capture(Contract::BINARY, 'mcp', '--url', 'http://127.0.0.1:9',
      input: JSON.generate({jsonrpc: '2.0', id: 1, method: 'tools/call', params: {name: 'corpora', arguments: {}}}) + "\nnot json\n")
    expect(code).to eq(0), error
    first, second = out.lines.map { |line| JSON.parse(line) }
    expect(first.dig('result', 'isError')).to be(true)
    expect(second.dig('error', 'code')).to eq(-32700)
  end
end
