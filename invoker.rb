require "open3"

Dir.chdir("/")
selector = /\/ruby-(1\.8|1\.9|2\.\d+|3\.\d+)/
rubies = Dir.glob("/all-ruby/bin/ruby-*").sort
rubies = rubies.grep_v(/preview|rc/)
rubies = rubies.group_by {|f| f[selector, 1] }
rubies = rubies.map do |ver, bins|
  [ver, bins.max_by {|f| f.scan(/\d+/).map {|n| n.to_i } }]
end.to_h
rubies.delete(nil)
inp = File.readable?("/inp") ? File.binread("/inp") : nil
result = rubies.sort.map do |ver, bin|
  Thread.new do
    out, err, status = Open3.capture3(bin, *ARGV, stdin_data: inp)
    [ver, out, err, status.exitstatus]
  end
end.map {|th| th.value }
result = Marshal.dump(result)
puts "ok:#{ result.size }"
print result
$stdout.close
