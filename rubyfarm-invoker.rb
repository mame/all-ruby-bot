require "open3"

Dir.chdir("/")
out, err, status = Open3.capture3("ruby", "-v")
out =~ /\((\d+-\d+-\d+[\w\d:]*) +\S+ +(\h+)\)/
rev = "#$2 (#$1)"
inp = File.readable?("/inp") ? File.binread("/inp") : nil
out, err, status = Open3.capture3("ruby", *ARGV, stdin_data: inp)
result = Marshal.dump([[rev, out, err, status.exitstatus]])
puts "ok:#{ result.size }"
print result
$stdout.close
