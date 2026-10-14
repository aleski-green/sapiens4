require 'rspec'
require_relative 'support/host'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = 'tmp/rspec-status.txt'
  config.define_derived_metadata(file_path: %r{/spec/(service|workflow|workspace|groups|scheduling)_spec.rb}) do |metadata|
    metadata[:host] = true
  end
  config.before(:each, :host) { @host = Host.new }
  config.after(:each, :host) { @host.close if @host }
  config.include(Module.new do
    def host; @host; end
    def chief; host.state.fetch('main_agent_id'); end
    def decision(event, **fields)
      {event: event, reason: 'Based on the supplied request.', evidence: ['Fixture evidence.']}.merge(fields)
    end
  end)
end
