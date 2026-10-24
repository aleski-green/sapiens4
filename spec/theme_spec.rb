RSpec.describe 'Shell color theme', :browser do
  def observe(mode)
    out, error, code = Contract.capture('node', 'spec/support/theme-browser.cjs', mode)
    expect(code).to eq(0), out + error
    JSON.parse(out)
  end

  def expect_theme(snapshot, theme)
    dark = theme == 'dark'
    label = "Switch to #{dark ? 'light' : 'dark'} theme"
    expect(snapshot).to include('theme' => theme, 'colorScheme' => theme)
    expect(snapshot['buttons']).to eq(Array.new(2) {
      {'text' => dark ? '☀' : '☾', 'label' => label, 'title' => label, 'pressed' => dark.to_s}
    })
  end

  {'default' => 'light', 'system-dark' => 'dark', 'stored-dark' => 'dark', 'unavailable-storage' => 'light'}.each do |mode, initial|
    it "applies #{mode} preferences and keeps every toggle accessible" do
      result = observe(mode)
      expect_theme(result['initial'], initial)
      toggled = initial == 'dark' ? 'light' : 'dark'
      expect_theme(result['clicked'], toggled)
      expect_theme(result['systemWithPreference'], toggled)
      expect_theme(result['cleared'], mode == 'system-dark' ? 'light' : 'dark')
      expect_theme(result['systemAfterClear'], mode == 'system-dark' ? 'dark' : 'light')
      expect_theme(result['reloaded'], mode == 'system-dark' ? 'light' : 'dark')
      expect(result['stored']).to eq(mode == 'unavailable-storage' ? nil : result['reloaded']['theme'])
    end
  end
end
