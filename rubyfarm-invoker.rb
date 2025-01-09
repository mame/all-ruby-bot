require "open3"

Dir.chdir("/")
out, err, status = Open3.capture3("ruby", "-v")
out =~ /\((\d+-\d+-\d+[\w\d:]*) +\S+ +(\h+)\)/
rev = "#$2 (#$1)"
inp = File.readable?("/inp") ? File.binread("/inp") : nil
result = ["prism", "parse.y"].map do |pa|
  out, err, status = Open3.capture3("ruby", "--parser=" + pa, *ARGV, stdin_data: inp)
  ["#{ rev }+#{ pa }", out, err, status.exitstatus]
end
result = Marshal.dump(result)
puts "ok:#{ result.size }"
print result
$stdout.close
