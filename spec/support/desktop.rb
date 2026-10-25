require_relative 'host'

class Desktop
  attr_reader :process

  def self.available?
    (RUBY_PLATFORM.include?('darwin') || Gem.win_platform?) && ENV['SAPIENS_TEST_BLINDLY4']
  end

  def self.binary
    return @binary if @binary
    @build = Dir.mktmpdir('sapiens desktop ')
    @binary = File.join(@build, Gem.win_platform? ? 'Probe.exe' : 'desktop')
    command = if Gem.win_platform?
      ['dotnet', 'build', 'spec/support/windows_accessibility/Probe.csproj', '-o', @build]
    else
      ['xcrun', 'swiftc', '-framework', 'Cocoa', '-framework', 'WebKit',
        'macos/Browser.swift', 'spec/support/macos/Desktop.swift', '-o', @binary]
    end
    out, error, code = Contract.capture(*command, timeout: 90)
    raise out + error unless code == 0
    @binary
  end

  def self.cleanup
    FileUtils.remove_entry(@build) if @build && File.directory?(@build)
  end

  def initialize(url = nil, process: nil, ready: true)
    @owns_process = process.nil?
    @process = process || Contract::Child.new(self.class.binary, url)
    Contract.wait(description: 'desktop startup') { @process.stdout.include?('READY') || @process.stdout.include?('TITLE:') } if ready
    Contract.wait(description: 'packaged desktop window') { !tree.empty? } unless ready
    control('activate')
  end

  def control(command, *args)
    out, error, code = Contract.capture(ENV.fetch('SAPIENS_TEST_BLINDLY4'), command,
      '--pid', process.pid.to_s, *args, timeout: 15, chdir: File.dirname(ENV.fetch('SAPIENS_TEST_BLINDLY4')))
    raise "Blindly4 #{command}: #{out}#{error}" unless code == 0
    JSON.parse(out)
  end

  def tree
    result = control('tree', '--depth', '50', '--max-nodes', '10000')
    raise 'Accessibility tree truncated' if result['truncated']
    flatten = lambda do |node, path|
      [node.reject { |key, _| key == 'children' }.merge('path' => path)] + node.fetch('children', []).each_with_index.flat_map do |child, i|
        flatten.call(child, path.empty? ? i.to_s : "#{path}.#{i}")
      end
    end
    result.fetch('tree').fetch('children', []).each_with_index.flat_map do |child, index|
      child['role'] == 'AXWindow' ? flatten.call(child, index.to_s) : []
    end
  end

  def label(node)
    %w[title description value].map { |key| node[key].to_s }.reject(&:empty?).uniq.join(' ')
  end

  def find(text, role: nil)
    Contract.wait(description: "accessible #{text.inspect}") do
      tree.find { |node| (!role || Array(role).include?(node['role'])) && (text.is_a?(Regexp) ? label(node).match?(text) :
        %w[title description value].any? { |key| node[key] == text }) }
    end
  end

  def text
    tree.map { |node| label(node) }.join("\n")
  end

  def see(text)
    Contract.wait(description: "visible #{text.inspect}") { value = self.text; value if text.is_a?(Regexp) ? value.match?(text) : value.include?(text) }
  end

  def press(text, role: %w[AXButton AXCheckBox AXRadioButton AXLink AXDisclosureTriangle AXPopUpButton])
    if Gem.win_platform? && text == 'Workspace options'
      # Chromium exposes this menu without UIA InvokePattern.
      click(text)
    else
      act_on(text, role: role) { |node| control('press', '--path', node.fetch('path')) }
    end
  end

  def fill(text, value)
    editable = %w[AXTextField AXTextArea AXComboBox]
    act_on(text, role: editable) { |node| control('focus', '--path', node.fetch('path')) }
    act_on(text, role: editable) { |node| control('set-value', '--path', node.fetch('path'), '--value', value) }
  end

  # A loading page may replace an accessible element between discovery and action.
  # Retry only a lookup failure, for which Blindly4 has performed no action.
  def act_on(text, role: nil)
    Contract.wait(description: "stable accessible #{text}") do
      begin
        yield find(text, role: role)
      rescue RuntimeError => error
        raise unless error.message.match?(/Path .* (does not|no longer) exist/)
        false
      end
    end
  end

  def click(text)
    node = find(text)
    control('click', '--x', (node.fetch('position')['x'] + node.fetch('size')['width'] / 2).to_i.to_s,
      '--y', (node['position']['y'] + node['size']['height'] / 2).to_i.to_s)
  end

  def key(value)
    control('key', '--key', value)
  end

  def reload
    key(Gem.win_platform? ? 'control+r' : 'command+r')
  end

  def close
    process.close if @owns_process
  end
end

module DesktopExamples
  def desktop; @desktop; end
  def desktop_host
    Gem.win_platform? ? Host.new(command: [Desktop.binary, '--runtime-dir', Contract::ROOT]) : Host.new
  end
  def start_desktop(url = nil)
    @host ||= desktop_host
    skip 'Network proxy window currently requires macOS WebKit' if Gem.win_platform? && url && url != host.url
    @desktop = Gem.win_platform? ? Desktop.new(process: host.process) : Desktop.new(url || host.url)
  end
end

RSpec.configure do |config|
  config.include DesktopExamples, :desktop
  config.before(:each, :desktop) do
    skip 'Requires macOS/Windows and SAPIENS_TEST_BLINDLY4 with accessibility access' unless Desktop.available?
  end
  config.after(:each, :desktop) do |example|
    if example.exception && @desktop
      FileUtils.mkdir_p(File.join(Contract::ROOT, 'tmp'))
      File.write(File.join(Contract::ROOT, 'tmp', 'desktop-failure.txt'), @desktop.text) rescue nil
    end
    @desktop&.close
    @host&.close
  end
  config.after(:suite) { Desktop.cleanup }
end
