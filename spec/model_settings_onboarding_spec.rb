require_relative 'spec_helper'

RSpec.describe 'Model settings and account integration', :host do
  it 'isolates Codex account holds from Claude, protects active Codex work and preserves model choices' do
    config = host.environment.fetch('SAPIENS_CONFIG_DIR')
    settings = host.api('GET', '/api/model-settings')
    settings['defaults'] = {provider: 'claude', model: 'claude-opus-5-5', effort: 'low'}
    settings['overrides'] = {chief => {provider: 'codex', model: 'fixture-general', effort: 'high'}}
    saved = host.api('PUT', '/api/model-settings', settings)
    researcher = host.agent

    # Profile holds cover Codex only, including admission and scheduled execution.
    Contract.atomic_json(File.join(config, 'account-state.json'), hold: 'review')
    expect(host.request('POST', "/api/agents/#{chief}/messages", {text: 'Wait for account review'}).first).to eq(409)
    host.turn(host.submit(researcher, 'Claude remains available'))
    expect(host.calls).not_to be_empty
    expect(host.calls.map { |call| call.fetch('provider') }.uniq).to eq(['claude'])
    expect(host.api('GET', '/api/model-settings')).to eq(saved)

    Contract.atomic_json(File.join(config, 'account-state.json'), hold: '')
    host.configure(rules: {'Assessing' => {block: true}})
    pending = host.submit(chief, 'Keep the current Codex account')
    Contract.wait { host.calls.any? { |call| call['provider'] == 'codex' } }
    expect(host.request('POST', '/api/host/onboarding', {action: 'change-account'}).first).to eq(409)
    expect(File.read(File.join(config, 'codex/auth.json'))).to eq('synthetic fixture authentication')
    host.release
    host.turn(pending)
    host.idle

    # A Claude-only installation can defer Codex setup and still execute work.
    host.environment['SAPIENS_CODEX_BINARY'] = File.join(host.root, 'missing-codex')
    File.delete(File.join(config, 'codex/auth.json'))
    host.restart
    expect(host.api('POST', '/api/host/onboarding', action: 'defer')).to include('completed' => true)
    count = host.calls.length
    host.turn(host.submit(researcher, 'Continue without Codex installed'))
    expect(host.calls.drop(count)).not_to be_empty
    expect(host.calls.drop(count).map { |call| call.fetch('provider') }.uniq).to eq(['claude'])
    expect(host.api('GET', '/api/model-settings')).to eq(saved)
    expect(host.request('POST', "/api/agents/#{chief}/messages", {text: 'Codex remains unavailable'}).first).to eq(409)
  end
end
