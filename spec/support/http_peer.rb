require 'webrick'
require_relative 'process'

class HTTPPeer
  attr_reader :url, :requests
  attr_accessor :handler

  def initialize(&handler)
    @requests, @handler = [], handler
    ready = Queue.new
    @server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [], StartCallback: -> { ready << true })
    @server.mount_proc('/') do |request, response|
      @requests << {method: request.request_method, path: request.unparsed_uri,
        body: request.body, local: request['x-sapiens-local']}
      status, body, headers = @handler.call(request)
      response.status = status
      response['Content-Type'] = 'application/json'
      (headers || {}).each { |key, value| response[key] = value }
      response.body = body.is_a?(String) ? body : JSON.generate(body)
    end
    @url = "http://127.0.0.1:#{@server.config[:Port]}"
    @thread = Thread.new { @server.start }
    Timeout.timeout(5) { ready.pop }
  end

  def close
    @server.shutdown
    raise 'HTTP fixture did not shut down' unless @thread.join(10)
  end
end
