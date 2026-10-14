require 'json'
require 'fileutils'
root = ENV.fetch('SAPIENS_BUILD_ENV')
config = JSON.parse(File.read(File.join(root, 'build.json')))
name = File.basename($PROGRAM_NAME)
case name
when 'git'
  if ARGV.first == 'submodule'
    FileUtils.mkdir_p('blindly4')
    FileUtils.cp(File.join(root, 'Package.swift'), 'blindly4/Package.swift')
  elsif ARGV.first == 'ls-remote' && config['revision']
    puts config['revision'] + "\trefs/heads/main"
  else
    args = ARGV.map { |arg| arg == 'https://github.com/aleski-green/sapiens4.git' ? ENV.fetch('SAPIENS_FIXTURE_UPSTREAM') : arg }
    exec(ENV.fetch('SAPIENS_REAL_GIT'), *args)
  end
when 'xcrun'
  if ARGV.include?('--show-sdk-path')
    puts File.join(root, 'sdk')
  elsif ARGV.include?('-typecheck')
    exit(config.fetch('sdk_failure', false) ? 1 : 0)
  elsif ARGV.include?('build') || ARGV.include?('-o')
    if config['build_failure']
      warn 'Fixture compiler source error'
      exit 1
    end
    output = ARGV.include?('-o') ? ARGV[ARGV.index('-o') + 1] :
      File.join(File.realpath(ARGV.fetch(ARGV.index('--package-path') + 1)), '.build/release/blindly4')
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
