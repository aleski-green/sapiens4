require 'socket'
require 'securerandom'
require_relative 'process'

class Relay
  attr_reader :root, :url, :token
  def initialize(beta: false)
    @root = Dir.mktmpdir('sapiens relay ')
    socket = TCPServer.new('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    @port, @beta = port, beta
    @url, @token = "http://127.0.0.1:#{port}", SecureRandom.urlsafe_base64(32)
    start
  rescue Exception
    close
    raise
  end
  def start
    @process = Contract::Child.new(Contract::PYTHON, '-m', 'sapiens.corpora.host.remote_relay',
      '--port', @port.to_s, '--origin', url, '--db', File.join(root, 'relay.sqlite3'),
      env: {'SAPIENS_RELAY_ADMIN_TOKEN' => token, 'SAPIENS_RELAY_BETA' => @beta ? '1' : nil,
        'RAILWAY_ENVIRONMENT_ID' => nil, 'PYTHONUTF8' => '1'})
    Contract.wait(description: 'relay startup') { @process.stdout.include?('Remote relay ready') }
    Contract.wait do
      begin
        request('GET', '/healthz').first == 200
      rescue Errno::ECONNREFUSED
        false
      end
    end
  end
  def stop
    @process.signal(Gem.win_platform? ? 'KILL' : 'TERM') if @process
    @process.close if @process
    @process = nil
  end
  def request(method, path, body = nil, bearer: token, headers: {})
    body = {} if method == 'POST' && body.nil?
    Contract.http(url + path, method, body, {'Authorization' => "Bearer #{bearer}"}.merge(headers))
  end
  def room
    status, body = request('POST', '/api/rooms', {})
    raise "Room creation failed: #{status}: #{body}" unless body['room']
    body
  end
  def close
    stop
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end
end

class RemotePeer
  def initialize(script: 'remote_peer.cjs')
    @input, @output, @error, @process = Open3.popen3('node', File.join(__dir__, script))
    @errors = Thread.new { @error.read }
  end
  def call(op, **fields)
    @input.puts(JSON.generate({op: op}.merge(fields)))
    line = Timeout.timeout(12) { @output.gets }
    raise 'Remote peer exited unexpectedly' unless line
    value = JSON.parse(line)
    raise value['error'] if value['error']
    value['value']
  end
  def close
    @input.close
    unless @process.join(5)
      Process.kill('KILL', @process.pid)
      @process.join
    end
    @output.close
    @errors.join
    @error.close
  end
end
