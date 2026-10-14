loop do
  File.write(ARGV.fetch(0), Process.clock_gettime(Process::CLOCK_MONOTONIC).to_s)
  sleep 0.02
end
