require 'json'
require 'fileutils'
root = ENV.fetch('SAPIENS_BUILD_ENV')
config = JSON.parse(File.read(File.join(root, 'build.json')))
name = File.basename($PROGRAM_NAME)
case name
when 'git'
  if ARGV.first == 'submodule'
    modules = ARGV.include?('--') ? ARGV.drop(ARGV.index('--') + 1) : %w[blindly4 libs4]
    if modules.include?('blindly4')
      FileUtils.mkdir_p('blindly4/macos')
      FileUtils.cp(File.join(root, 'blindly-build.sh'), 'blindly4/macos/build.sh')
      File.chmod(0755, 'blindly4/macos/build.sh')
    end
    if modules.include?('libs4') && !config['missing_vendor']
      FileUtils.mkdir_p('libs4')
      %w[web license].each { |folder| FileUtils.cp_r(File.join(ENV.fetch('SAPIENS_FIXTURE_LIBS'), folder), 'libs4') }
    end
  elsif ARGV.first == 'ls-remote' && config['revision']
    puts config['revision'] + "\trefs/heads/main"
  else
    args = ARGV.map { |arg| arg == 'https://github.com/aleski-green/sapiens4.git' ? ENV.fetch('SAPIENS_FIXTURE_UPSTREAM') : arg }
    exec(ENV.fetch('SAPIENS_REAL_GIT'), *args)
  end
when 'cargo'
  raise 'Expected Rust release build' unless ARGV.first == 'build' && ARGV.include?('--release')
  if config['build_failure']
    warn 'Fixture Rust compiler source error'
    exit 1
  end
  target = File.expand_path(ARGV.fetch(ARGV.index('--target-dir') + 1))
  raise 'Build fixture escaped its temporary installation' unless target.start_with?(File.realpath(root) + '/')
  output = File.join(target, 'release/blindly4')
  FileUtils.mkdir_p(File.dirname(output))
  File.write(output, "#!/bin/sh\n[ \"$1\" = schema ] || exit 64\n" +
    (config['schema_failure'] ? "echo 'Fixture schema failed' >&2\nexit 1\n" : "echo '{\"schemaVersion\":1,\"commands\":[]}'\n"))
  File.chmod(0755, output)
when 'xcrun'
  if ARGV.include?('--show-sdk-path')
    puts File.join(root, 'sdk')
  elsif ARGV.include?('-typecheck')
    exit(config.fetch('sdk_failure', false) ? 1 : 0)
  elsif ARGV.include?('-o')
    if config['build_failure']
      warn 'Fixture compiler source error'
      exit 1
    end
    output = ARGV[ARGV.index('-o') + 1]
    raise 'Build fixture escaped its temporary installation' unless output.start_with?(File.realpath(root) + '/')
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, "#!/bin/sh\nexit 0\n")
    File.chmod(0755, output)
  end
when 'codesign'
  if config['invalid_signature'] && ARGV.last.include?(config['invalid_signature'])
    warn 'Fixture signature rejected'
    exit 1
  end
when 'ditto'
  FileUtils.cp_r(ARGV[0], ARGV[1])
  File.write(File.join(ARGV[1], 'Contents/Info.plist'), 'corrupt') if config['corrupt_stage']
end
