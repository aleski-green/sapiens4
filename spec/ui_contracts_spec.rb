RSpec.describe 'PureScript UI behavior preserved from the JavaScript implementation' do
  Dir[File.join(Contract::ROOT, 'spec/fixtures/browser/*.json')].sort.each do |fixture|
    name = File.basename(fixture, '.json')
    checks = JSON.parse(File.read(fixture))
    describe name do
      before(:context) do
        out, error, code = Contract.capture('node', "spec/support/#{name}-browser.cjs", timeout: 90)
        raise "Browser probe failed (#{code}): #{error.lines.reject { |line| line.length > 2000 }.join}\n#{out[-2000..]}" unless code == 0
        @observations = JSON.parse(out)
      end

      it 'reports every observation in the original contract' do
        expect(@observations.map { |item| item.fetch('id') }).to eq(checks.map { |item| item.fetch('id') })
      end

      checks.each_with_index do |check, index|
        it "#{check.fetch('matcher')} #{check.fetch('expression')} (#{index + 1})" do
          actual = @observations.fetch(index).fetch('value')
          expected = check.fetch('expected')
          case check.fetch('matcher')
          when 'identity'
            expect(actual.fetch('node')).to eq(actual.fetch('reference'))
          when 'unique'
            expect(actual).to eq(actual.uniq)
          when 'equal', 'deepEqual', 'ok'
            expect(actual).to eq(expected)
          when 'match', 'throws', 'doesNotMatch'
            flags = expected.fetch('flags').include?('i') ? Regexp::IGNORECASE : 0
            pattern = Regexp.new(expected.fetch('source'), flags)
            if check.fetch('matcher') == 'doesNotMatch'
              expect(actual).not_to match(pattern)
            else
              expect(actual).to match(pattern)
            end
          else
            raise "Unknown browser matcher #{check.fetch('matcher')}"
          end
        end
      end
    end
  end
end
