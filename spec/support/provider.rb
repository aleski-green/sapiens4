require 'json'
require 'securerandom'
require 'net/http'
require 'rbconfig'

root = ENV.fetch('SAPIENS_CONTRACT_ENV')
config = JSON.parse(File.read(File.join(root, 'provider.json')))
if ARGV.include?('--version')
  puts config.fetch('version', 'codex-cli 0.158.0')
  exit
end

# Claude account commands. Claude counts as signed in unless a spec turns on
# `claude_accounts`; then the login is a marker file in CLAUDE_CONFIG_DIR, so a
# spec can see which folder Sapiens signed in to.
if ARGV.first == 'auth'
  home = ENV['CLAUDE_CONFIG_DIR'].to_s
  marker = File.join(home, '.fixture-login')
  File.open(File.join(root, 'claude-auth.jsonl'), 'a') do |file|
    file.puts JSON.generate(args: ARGV, home: home, pid: Process.pid,
      inherited: ENV.keys.grep(/\A(ANTHROPIC_|CLAUDE_CODE_)/).sort)
  end
  exit 2 if home.empty?
  case ARGV[1]
  when 'status'
    exit(!config['claude_accounts'] || File.exist?(marker) ? 0 : 1)
  when 'logout'
    File.delete(marker) if File.exist?(marker)
    exit 0
  when 'login'
    STDOUT.sync = true
    puts 'Opening browser to sign in…'
    puts "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=fixture&state=#{SecureRandom.hex(8)}"
    sleep 0.02 until File.exist?(File.join(root, 'claude-login-approved')) || File.exist?(File.join(root, 'claude-login-fails'))
    exit 1 if File.exist?(File.join(root, 'claude-login-fails'))
    File.write(marker, 'signed in')
    puts 'Login successful.'
    exit 0
  end
  exit 2
end

exit 0 if ARGV.include?('login') && ARGV.include?('status')

# Model discovery uses the real provider process boundary, without a model turn.
if ARGV.include?('app-server')
  STDOUT.sync = true
  initialized = false
  default_model = {'model' => 'fixture-general', 'displayName' => 'Fixture General',
    'hidden' => false, 'isDefault' => true, 'defaultReasoningEffort' => 'high',
    'supportedReasoningEfforts' => [{'reasoningEffort' => 'low'}, {'reasoningEffort' => 'high'}]}
  pages = config.fetch('catalog_pages', [{'data' => [default_model], 'nextCursor' => nil}])
  STDIN.each_line do |line|
    message = JSON.parse(line)
    File.open(File.join(root, 'discovery.jsonl'), 'a') do |file|
      file.puts JSON.generate(message.merge('pid' => Process.pid))
    end
    case message.fetch('method')
    when 'initialize'
      puts JSON.generate(id: message.fetch('id'), result: {})
    when 'initialized'
      initialized = true
    when 'model/list'
      raise 'Missing initialized notification' unless initialized
      if config['catalog_block']
        sleep 0.02 until File.exist?(File.join(root, 'released'))
      end
      if config['catalog_error']
        puts JSON.generate(id: message.fetch('id'), error: {code: -1, message: 'Fixture catalog failure'})
      elsif config['catalog_malformed']
        puts 'not-json'
      else
        cursor = message.fetch('params')['cursor']
        page = pages.fetch(cursor ? Integer(cursor) : 0)
        puts JSON.generate(method: 'fixture/notification', params: {})
        puts JSON.generate(id: message.fetch('id'), result: page)
      end
    end
  end
  exit
end

# Claude discovery has its own control protocol and never submits a user prompt.
if ARGV.include?('--input-format')
  STDOUT.sync = true
  STDIN.each_line do |line|
    request = JSON.parse(line)
    File.open(File.join(root, 'claude-discovery.jsonl'), 'a') { |file| file.puts(JSON.generate(request.merge('pid' => Process.pid))) }
    raise 'Unexpected Claude discovery request' unless request.dig('request', 'subtype') == 'initialize'
    sleep 0.02 until !config['claude_catalog_block'] || File.exist?(File.join(root, 'released'))
    models = config.fetch('claude_models', [
      {value: 'default', resolvedModel: 'claude-opus-5-5', displayName: 'Default (recommended)', supportsEffort: true, supportedEffortLevels: %w[low medium high xhigh max]},
      {value: 'opus', resolvedModel: 'claude-opus-5-5', displayName: 'Opus 5.5', supportsEffort: true, supportedEffortLevels: %w[low medium high xhigh max]},
      {value: 'legacy', resolvedModel: 'claude-fixture-no-effort', displayName: 'Fixture no effort'}
    ])
    if config['claude_catalog_malformed']
      puts 'not-json'
    else
      puts JSON.generate(type: 'control_response', response: {
        subtype: config['claude_catalog_error'] ? 'error' : 'success',
        request_id: request.fetch('request_id'), response: {models: models}})
    end
  end
  exit
end

claude = ARGV.include?('--print')
text = STDIN.read
context = text.include?("\nContext:\n") ? JSON.parse(text.split("\nContext:\n", 2).last) : {}
node = text[/decision at node (\w+)/, 1] || (text.start_with?('You are acting as yourself inside') ? 'group' :
  text.start_with?('You are the current Lead updating') ? 'group-memo' : 'other')
owner = context['selfId'] || File.basename(Dir.pwd)
key = "#{owner}:#{node}"
rule = config.fetch('rules', {}).fetch(key, config.fetch('rules', {}).fetch(node, {}))
matching = config.fetch('messages', []).find { |item| context.fetch('originalIntent', text).include?(item.fetch('contains')) }
rule = rule.merge(matching.fetch('rule')) if matching
record = {provider: claude ? 'claude' : 'codex', owner: owner, node: node, prompt: text, args: ARGV, cwd: Dir.pwd,
          pid: Process.pid, started: Time.now.to_f, agency_run: ENV['SAPIENS_AGENCY_RUN']}
path = File.join(root, 'calls', SecureRandom.hex(12) + '.json')
if rule['child']
  record[:heartbeat] = path + '.heartbeat'
  record[:child] = Process.spawn(RbConfig.ruby, File.join(__dir__, 'heartbeat.rb'), record[:heartbeat],
    **(Gem.win_platform? ? {} : {pgroup: true}), out: File::NULL, err: File::NULL)
end
File.write(path + '.new', JSON.generate(record))
File.rename(path + '.new', path)
if rule.fetch('block', config.fetch('block', false))
  sleep 0.02 until File.exist?(File.join(root, rule.fetch('gate', 'released'))) || File.exist?(File.join(root, 'released'))
end
if rule.fetch('fail', config.fetch('fail', false))
  warn 'Scripted provider failure'
  exit 1
end
Array(rule['actions']).each do |action|
  if action['write']
    File.write(File.expand_path(action['write'], Dir.pwd), action.fetch('content'))
  elsif action['generated_command']
    require_relative 'generated_command'
    result = GeneratedCommand.capture(Dir.pwd, action.fetch('generated_command'), action.fetch('arguments'))
    record[:commands] ||= []
    record[:commands] << result
    File.write(path + '.new', JSON.generate(record))
    File.rename(path + '.new', path)
  elsif action['gate']
    sleep 0.02 until File.exist?(File.join(root, action['gate'])) || File.exist?(File.join(root, 'released'))
  elsif action['control']
    uri = URI(JSON.parse(File.read('host-control.json')).fetch('url'))
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'], request['X-Sapiens-Local'] = 'application/json', '1'
    request.body = JSON.generate(action['control'].merge('agencyRun' => ENV['SAPIENS_AGENCY_RUN']).reject { |_, v| v.nil? })
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.read_timeout = 5
    response = http.request(request)
    raise "Host control failed: #{response.code}: #{response.body}" unless response.code.to_i == 200
  end
end
defaults = {
  'Assessing' => {event: 'FitsSpecialization', mode: config.fetch('mode', 'Repl'), reply: 'Contract test reply'},
  'ReadyToWork' => {event: 'TaskPrepared', taskType: 'research', specification: {
    objective: 'Compare the products.', inputs: [], expectedOutputs: ['A comparison'], completionCriteria: ['Return a sourced comparison.']}},
  'Execution' => {event: 'Outcome', reply: 'Verified comparison', outcome: {status: 'Completed', satisfiedCriteria: ['Return a sourced comparison.'], artifacts: []}},
  'Delegation' => {event: 'HandoffPrepared', request: 'Compare the products.'},
  'CreatingSapi' => {event: 'SapiSpecified', name: 'NewResearcher', role: 'Research'}
}
reply = rule.fetch('response') do
  if defaults[node]
    defaults[node].merge(reason: 'Based on the supplied request.', evidence: ['Fixture evidence.'])
  else
    'Contract test reply'
  end
end
reply = JSON.generate(reply) unless reply.is_a?(String)
if claude
  puts JSON.generate(type: 'system', subtype: 'init', session_id: 'fixture-claude-session')
  puts JSON.generate(type: 'assistant', message: {content: [{type: 'text', text: 'Intermediate text must not complete the turn'}]})
  unless config['claude_missing_result']
    failed = config.fetch('claude_result_error', false)
    puts JSON.generate(type: 'result', subtype: failed ? 'error_during_execution' : 'success',
      is_error: failed, result: reply, errors: failed ? ['Fixture Claude error'] : [])
  end
else
  puts JSON.generate(type: 'thread.started', thread_id: 'fixture-session')
  puts JSON.generate(type: 'item.completed', item: {type: 'agent_message', text: reply})
end
