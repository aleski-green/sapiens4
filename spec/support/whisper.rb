require 'socket'
require 'json'

# A stand-in for whisper-server on this computer. It answers every /inference request with the
# same text, so voice specs do not need the real model, and notes whether audio arrived and how
# many requests came. With status: 500 it plays a Whisper that fails to transcribe.
class WhisperStub
  attr_reader :url, :requests

  def initialize(text, status: 200)
    @text, @status, @audio, @requests = text, status, false, 0
    @server = TCPServer.new('127.0.0.1', 0)
    @url = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new do
      loop { serve(@server.accept) }
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def audio_received; @audio; end

  def close
    @server.close
    @thread.join(2)
  end

  private

  def serve(client)
    request_line = client.gets.to_s
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(':', 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = headers['transfer-encoding'].to_s.include?('chunked') ? chunked(client) : client.read(headers['content-length'].to_i)
    @audio ||= request_line.include?('/inference') && body.to_s.b.include?('RIFF')
    @requests += 1
    reply = JSON.generate(@status == 200 ? {text: @text} : {error: 'stub failure'})
    client.write("HTTP/1.1 #{@status} #{@status == 200 ? 'OK' : 'Error'}\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
  ensure
    client.close
  end

  def chunked(client)
    body = +''
    loop do
      size = client.gets.to_s.strip.to_i(16)
      break client.gets if size.zero?
      body << client.read(size)
      client.gets
    end
    body
  end
end
