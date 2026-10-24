RSpec.describe 'PureScript browser distribution' do
  it 'rebuilds the shipped browser assets from pinned PureScript sources' do
    Dir.mktmpdir('sapiens-ui-build-') do |directory|
      out, error, code = Contract.capture('node', 'web/shell/build.cjs', '--output-dir', directory, timeout: 180)
      expect(code).to eq(0), out + error
      assets = Dir.glob(File.join(directory, 'web/**/*.js')).map { |file| file.delete_prefix(directory + '/') }.sort
      expect(assets).to eq(%w[
        web/features/corpora.js web/features/relay-servers.js web/features/remote-code.js
        web/features/remote-install.js web/features/remote-onboarding.js web/features/remote-session.js
        web/features/remote-transport.js web/features/task-ui.js web/shell/application.js web/shell/components.js
        web/shell/panel-layout.js web/shell/sw.js web/shell/text-format.js web/theme/sapi-theme.js
      ])
      assets.each do |asset|
        expect(File.binread(File.join(directory, asset))).to eq(File.binread(File.join(Contract::ROOT, asset))),
          "#{asset} differs from its PureScript source; run node web/shell/build.cjs"
      end
    end
  end
end
