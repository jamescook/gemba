require "./gemba"

begin
  Gemba::CLI.run(ARGV)
rescue ex : Gemba::CLI::Error
  STDERR.puts "Error: #{ex.message}"
  exit 1
end
