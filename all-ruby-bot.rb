require "sinatra/base"
require "shellwords"
require "tempfile"
require "timeout"
require "net/http"
require "logger"

SLACK_API_TOKEN = ENV["ALL_RUBY_BOT_SLACK_API_TOKEN"]
SLACK_APP_SECRET_KEY = ENV["ALL_RUBY_BOT_SLACK_APP_SECRET_KEY"]
EMOJI = ENV.fetch("ALL_RUBY_BOT_EMOJI", "thumbsup")
ENABLE_MASTER = ENV["ALL_RUBY_ENABLE_MASTER"]
TIMEOUT = ENV.fetch("ALL_RUBY_BOT_TIMEOUT", "10").to_i

Thread.report_on_exception = true

class AllRubyBot < Sinatra::Base
  configure do
    enable :logging
  end

  configure :development do
    set :logging, Logger::DEBUG
  end

  configure :production do
    set :logging, Logger::INFO
  end

  get "/" do
    "Hello?"
  end

  # Slack App entrypoint
  post "/" do
    body = request.body.read

    return "{}" unless verify_signature(
      request.env["HTTP_X_SLACK_REQUEST_TIMESTAMP"],
      body,
      request.env["HTTP_X_SLACK_SIGNATURE"]
    )

    json = JSON.parse(body, symbolize_names: true)
    case json[:type]
    when "url_verification"
      JSON.generate(json)
    when "event_callback"
      event = json[:event]
      if event[:type] == "app_mention" && !event.key?(:bot_id)
        Thread.new { on_mention(json) }
      end
      ""
    else
      ""
    end
  end

  # Slack App verification
  def verify_signature(timestamp, body, sig_actual)
    msg = ["v0", timestamp, body].join(":")
    sig_expected = "v0=" + OpenSSL::HMAC::hexdigest(OpenSSL::Digest::SHA256.new, SLACK_APP_SECRET_KEY, msg)
    sig_actual == sig_expected
  end

  # main event handler: all-ruby bot has been mentioned
  def on_mention(json)
    event = json[:event]
    authed_users = json[:authed_users]
    text = event[:text].strip
    text = text.gsub(Regexp.union(*authed_users.map {|s| "<@#{ s }>" }), "").strip

    json = command(text) do |progress|
      case progress
      when :start
        post("reactions.add", channel: event[:channel], name: EMOJI, timestamp: event[:ts])
      when :end
        post("reactions.remove", channel: event[:channel], name: EMOJI, timestamp: event[:ts])
      end
    end

    if json
      json[:thread_ts] = event[:thread_ts] || event[:ts] if json[:thread_ts]
      post("chat.postMessage", channel: event[:channel], **json)
    end
  end

  # parse and execute command
  def command(text, &progress_report)
    case text.strip
    when "", "help"
      { text: help_message, thread_ts: true }

    when /\A(.*?)\s*(?:```((?:.|\n)*)```)?\s*\z/
      cmd, inp = $1.strip, $2&.strip

      logger.info "command(#{ cmd ? cmd.dump: "nil" }, #{ inp ? inp.dump : "nil" })"

      cmd = cmd.gsub("\u00a0", "")
      cmd = cmd.gsub(/[“”]/, ?")
      cmd = cmd.gsub(/[‘’]/, ?')

      cmd = unescape(cmd)
      inp = unescape(inp) if inp

      if cmd.start_with?("-") || inp
        # Looks valid command format:
        #
        # * @all-ruby -e 'puts "Hello"', or
        # * @all-ruby ```puts "Hello"```

        json = execute_ruby(cmd, inp, &progress_report)

        json = { text: json, thread_ts: true } if json.is_a?(String)

        json
      end
    end
  end

  # run command in docker
  def execute_ruby(cmd, inp)
    begin
      cmd = Shellwords.shellsplit(cmd)
    rescue ArgumentError
      return "command parse error: ｀#{ escape($!.to_s) }｀"
    end

    yield :start

    outputs = Tempfile.open do |f|
      f.write("\uFEFF" + inp)
      f.close
      inp = f.path
      types = ["all-ruby"]
      types << "rubyfarm" if ENABLE_MASTER
      types.map do |type|
        Thread.new do
          volume = {
            File.join(__dir__, "/#{ type }-invoker.rb") => "/invoker.rb",
            f.path => "/inp",
          }
          DockerInvoker.docker_run(TIMEOUT, "rubylang/#{ type }", volume, ["ruby", "/invoker.rb"] + cmd)
        end
      end.map {|th| th.value }
    end

    yield :end

    outputs = outputs.flat_map do |output|
      return "time limit exceeded (#{ TIMEOUT } sec.)" if output.nil?
      if output =~ /\Aok:(\d+)\n/
        Marshal.load($')
      else
        return escape(output.lines.first)
      end
    end
    return format_outputs(outputs)
  end

  # post json to Slack
  def post(method, **params)
    params["token"] = SLACK_API_TOKEN
    json = JSON.parse(
      Net::HTTP.post_form(
        URI.parse("https://slack.com/api/" + method),
        params
      ).body
    )
    return json if json["ok"]
    json
  end

  # helpers for handling Slack message
  def escape(s)
    s.gsub(/[&<>｀]/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "｀" => "`")
  end
  def unescape(s)
    s = s.gsub(/<(?:[^<>]*?\|)?([^<>]*)>/) { $1 }
    s.gsub(/&(amp|lt|gt);/, "&amp;" => "&", "&lt;" => "<", "&gt;" => ">")
  end

  # convert Ruby outputs to Slack message json
  def format_outputs(rs)
    rs = rs.map.with_index {|res, i| [i] + res }
    rs = rs.group_by {|i, ver, *res| res }
    attachments = rs.map do |(out, err, status), rs|
      vers = format_versions(rs.map {|i, ver,| [i, ver] })
      out.force_encoding("UTF-8")
      err.force_encoding("UTF-8")
      out = out.chomp.empty? ? nil : "｀｀｀#{ escape(out) }｀｀｀"
      err = err.chomp.empty? ? nil : "｀｀｀#{ escape(err) }｀｀｀"
      if out && err
        text = out + " " + err
      elsif out || err
        text = out || err
      else
        text = "(no stdout :speak_no_evil:)"
      end
      json = {
        title: "#{ status == 0 ? ":ok:" : ":x:" } #{ vers }",
        text: text,
        color: status == 0 ? "good" : "danger",
        mrkdwn_in: ["text"],
      }
      json[:footer] = "exit: #{ status }" if status != 0
      json
    end
    json = { attachments: JSON.generate(attachments) }
    json[:thread_ts] = true if attachments.size >= 2 || attachments[0][:text].count("\n") > 10
    json
  end

  # pretty formatting of version numbers
  #
  # input: [[0, "1.8.7"], [1, "1.9"], [2, "2.0"], [4, "2.2"]]
  # output: "1.8.7--2.0, 2.2"
  def format_versions(vers)
    prev = vers[0][0]
    vers.slice_before do |i, ver|
      prev, prev2 = i, prev
      prev2 + 1 != i
    end.map do |vers|
      vers = vers.map {|i, ver| ver }
      vers.length <= 2 ? vers.join(",") : "#{vers.first} -- #{vers.last}"
    end.join(",")
  end

  def help_message
    <<~END
      Usage:
      ```
      @all-ruby -e 'puts "Hello"'
      ```
      ｀｀｀
      @all-ruby
      ```
      puts "Hello"
      ```
      ｀｀｀
    END
  end
end

module DockerInvoker
  module_function

  def docker_run(timeout, image, volume, cmd)
    name = "all-ruby-bot-#{ $$ }-#{ Time.now.to_f.to_s.tr(".", "-") }"
    docker_run_cmd = [
      "docker", "run", "--rm",
      "--net=none",
      "-m", "100M", "--oom-kill-disable",
      "--pids-limit", "1024",
      "--name", name,
    ]
    volume.each do |from, to|
      docker_run_cmd << "-v" << (from + ":" + to + ":ro")
    end
    docker_run_cmd << image
    invoke(timeout, *docker_run_cmd, *cmd)

  ensure
    invoke(timeout, "docker", "kill", name)
  end

  def invoke(timeout, *cmd)
    out_r, out_w = IO.pipe(Encoding::BINARY)
    pid = spawn(*cmd, :in => File::NULL, [:out, :err] => out_w, :pgroup => true)
    th = Process.detach(pid)
    out_w.close
    begin
      out = Timeout.timeout(timeout) { out_r.read }
    rescue Timeout::Error
      begin
        Process.kill(:KILL, -pid)
      rescue Errno::ESRCH
      end
    ensure
      out_r.close
    end
    th.join
    out
  end
end
