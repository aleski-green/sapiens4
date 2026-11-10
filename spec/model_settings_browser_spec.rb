require_relative 'support/desktop'

RSpec.describe 'Model settings', :desktop do
  def open_models
    desktop.click('Menu')
    desktop.press('Workspace & settings')
    desktop.press('Models')
    desktop.see('Models for this corpora and its Sapis.')
    expect(desktop.tree.any? { |node| node['role'] == 'AXButton' && %w[title description].any? { |key| node[key] == 'Close' } }).to eq(false)
  end

  def picker(field, value = nil)
    desktop.find(value ? "#{field}: #{value}" : /^#{Regexp.escape(field)}: /, role: %w[AXButton AXPopUpButton])
  end

  def open_picker(field)
    desktop.press(/^#{Regexp.escape(field)}: /)
  end

  def expect_saved_and_closed
    desktop.see('Model settings saved.')
    toast = desktop.find('Model settings saved.')
    window = desktop.tree.find { |node| node['role'] == 'AXWindow' }
    expect(toast.fetch('position').fetch('y')).to be > window.fetch('position').fetch('y') + window.fetch('size').fetch('height') / 2
    desktop.find('Message ChiefSapi')
    expect(desktop.text).not_to include('Save and apply')
    expect(desktop.tree.any? { |node| node['role'] == 'AXButton' && node['description'] == 'Close dialog' }).to eq(false)
  end

  it 'edits both pages, validates an override, saves and executes it, restores inheritance and discards later edits' do
    start_desktop
    original = host.api('GET', '/api/model-settings')
    desktop.fill('Message ChiefSapi', 'Keep my unsent message')
    open_models
    desktop.see('Changes apply to new runs. Running work is unchanged.')
    desktop.press('Default provider Claude')
    desktop.see('Recommended: Opus 5.5 · medium')
    desktop.press('Sapi customization')
    picker('Sapi', 'ChiefSapi')
    desktop.see('Global default: Claude · Opus 5.5 · medium')
    desktop.press('Use corpora default')
    desktop.press('Sapi provider Codex')
    desktop.press('Global settings')
    desktop.see('Cannot save yet. Check model availability and effort for: Sapi customization — ChiefSapi.')
    expect(desktop.find('Save and apply', role: 'AXButton')['enabled']).to eq(false)
    desktop.press('Sapi customization')
    desktop.press('Customize sapi model')
    picker('Sapi model', 'Fixture General')
    desktop.press('Global settings')
    desktop.see('Recommended: Opus 5.5 · medium')
    expect(host.api('GET', '/api/model-settings')).to eq(original)
    desktop.press('Manage AI connections')
    desktop.see('Your AI lineup')
    desktop.press('Back to model settings')
    desktop.see('Recommended: Opus 5.5 · medium')
    expect(host.api('GET', '/api/model-settings')).to eq(original)
    desktop.press('Sapi customization')
    picker('Sapi model', 'Fixture General')
    desktop.click('Save and apply')
    expect_saved_and_closed
    expect(desktop.find('Message ChiefSapi')['value']).to eq('Keep my unsent message')
    saved = host.api('GET', '/api/model-settings')
    expect(saved.fetch('defaults')).to include('provider' => 'claude')
    expect(saved.fetch('overrides').fetch(chief)).to include('provider' => 'codex', 'model' => 'fixture-general', 'effort' => 'high')
    host.turn(host.submit(chief, 'Use the Sapi override'))
    expect(host.calls).not_to be_empty
    host.calls.each { |call| expect(call.fetch('args')).to include('model="fixture-general"', 'model_reasoning_effort="high"') }

    open_models
    desktop.press('Sapi customization')
    picker('Sapi effort', 'high')
    desktop.press('Use corpora default')
    desktop.see('Follows global settings.')
    desktop.click('Save and apply')
    expect_saved_and_closed
    expect(host.api('GET', '/api/model-settings').fetch('overrides')).not_to have_key(chief)
    previous_calls = host.calls.length
    host.turn(host.submit(chief, 'Use the inherited model'))
    calls = host.calls.drop(previous_calls)
    expect(calls).not_to be_empty
    calls.each do |call|
      expect(call.fetch('provider')).to eq('claude')
      expect(call.fetch('args')).to include('--model', 'claude-opus-5-5', '--effort', 'medium')
    end
    saved = host.api('GET', '/api/model-settings')
    open_models
    desktop.press('Default provider Codex')
    desktop.press('Close dialog')
    expect(host.api('GET', '/api/model-settings')).to eq(saved)
    open_models
    desktop.see('Recommended: Opus 5.5 · medium')
    expect(desktop.find('Save and apply', role: 'AXButton')['enabled']).to eq(false)
    desktop.press('Close dialog')
  end

  it 'navigates themed pickers, cancels without selection, resets unsupported effort and persists a model without effort' do
    start_desktop
    host.configure(catalog_pages: [{data: [
      {model: 'fixture-general', displayName: 'Fixture General', hidden: false, isDefault: true,
       defaultReasoningEffort: 'low', supportedReasoningEfforts: [{reasoningEffort: 'low'}, {reasoningEffort: 'ultra'}]},
      {model: 'fixture-quick', displayName: 'Fixture Quick', hidden: false, isDefault: false,
       defaultReasoningEffort: 'low', supportedReasoningEfforts: [{reasoningEffort: 'low'}]}
    ]}])
    open_models
    desktop.press('Customize default model')
    open_picker('Default effort')
    desktop.key('home')
    desktop.key('down')
    desktop.key('return')
    picker('Default effort', 'low')
    open_picker('Default effort')
    desktop.key('u')
    desktop.key('return')
    picker('Default effort', 'ultra')
    open_picker('Default model')
    desktop.key('end')
    desktop.key('escape')
    picker('Default model', 'Fixture General')
    expect(desktop.text).to include('Save and apply')
    open_picker('Default model')
    desktop.press('Dismiss choices')
    picker('Default model', 'Fixture General')
    open_picker('Default model')
    desktop.key('end')
    desktop.key('return')
    picker('Default model', 'Fixture Quick')
    picker('Default effort', 'Model default (low)')
    open_picker('Default effort')
    expect(desktop.text).not_to include('ultra')
    desktop.key('home')
    desktop.key('tab')
    picker('Default effort', 'Model default (low)')
    desktop.press('Default provider Claude')
    desktop.press('Customize default model')
    open_picker('Default model')
    desktop.key('end')
    desktop.key('return')
    picker('Default model', 'Fixture no effort')
    expect(picker('Default effort', 'Provider default')['enabled']).to eq(false)
    desktop.click('Save and apply')
    expect_saved_and_closed
    open_models
    picker('Default model', 'Fixture no effort')
    expect(picker('Default effort', 'Provider default')['enabled']).to eq(false)
    desktop.press('Close dialog')
  end

  it 'recovers discovery and save failures, preserves edits on conflict and reloads the persisted revision' do
    start_desktop
    host.configure(catalog_error: true)
    open_models
    desktop.see('Retry model discovery')
    host.configure(catalog_error: false)
    desktop.click('Retry model discovery')
    desktop.see('Recommended: Astra · medium')
    desktop.press('Customize default model')
    picker('Default model', 'Fixture General')
    original = host.api('GET', '/api/model-settings')
    host.configure(catalog_error: true)
    desktop.click('Save and apply')
    desktop.see('Codex could not list models. Check its login and CLI version.')
    picker('Default model', 'Fixture General')
    expect(host.api('GET', '/api/model-settings')).to eq(original)
    host.configure(catalog_error: false)
    host.api('PUT', '/api/model-settings', {
      revision: original.fetch('revision'), defaults: {provider: 'codex', model: 'fixture-general', effort: 'high'}, overrides: {}})
    desktop.click('Save and apply')
    desktop.see('Model settings changed elsewhere. Close and reopen Models before saving.')
    picker('Default model', 'Fixture General')
    expect(host.api('GET', '/api/model-settings').fetch('revision')).to eq(original.fetch('revision') + 1)
    desktop.press('Close dialog')
    open_models
    picker('Default effort', 'high')
    expect(desktop.find('Save and apply', role: 'AXButton')['enabled']).to eq(false)
    desktop.press('Default provider Claude')
    desktop.click('Save and apply')
    expect_saved_and_closed
    open_models
    desktop.see('Recommended: Opus 5.5 · medium')
    desktop.press('Close dialog')
  end
end
