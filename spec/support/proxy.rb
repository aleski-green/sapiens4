require_relative 'http_peer'

# A real HTTP boundary around the real host. A scenario can delay/fail a response
# without importing UI code, replacing fetch, or exposing a test endpoint.
class HostProxy
  attr_reader :url
  def initialize(host, &filter)
    @server = HTTPPeer.new do |request|
      status, body, headers = host.request(request.request_method, request.unparsed_uri, request.body)
      response = [status, body, headers.transform_values { |values| values.join(', ') }.reject { |key, _| %w[content-length transfer-encoding connection].include?(key) }]
      filter.call(request, response) || response
    end
    @url = @server.url
  end
  def close; @server.close; end
end
