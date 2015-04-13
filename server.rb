require 'sinatra'
require 'sinatra/streaming'
require_relative 'render'

set :server, 'puma'
set :port, (ENV['PORT'] || 8580).to_i

get '/update' do
  headers 'Content-Type' => 'text/plain'
  stream do |out|
    begin
      update_index(Logger.new(out))
    rescue => e
      out.puts e.to_s
      e.backtrace.each {|bt|
        out.write "  "
        out.puts bt
      }
    end
  end
end

get '/embulk-latest.jar' do
  version = get_latest_version
  url = "https://dl.bintray.com/embulk/maven/embulk-#{version}.jar"
  redirect to(url), 302
end

def get_latest_version
  begin
    File.open("embulk.version") {|f|
      if Time.now - f.stat.mtime < 5*60  # cache 5 minutes
        return f.read
      end
    }
  rescue Errno::ENOENT
  end

  require 'faraday'
  require 'httpclient'
  Faraday.default_adapter = :httpclient
  f = Faraday.new('https://bintray.com')
  r = f.get("/embulk/maven/embulk/_latestVersion")
  version = /(\d+\.\d+[^\/]+)/.match(r["Location"])[1]

  File.write("embulk.version", version)
  return version
end
