require 'sinatra'
require 'sinatra/streaming'

set :server, 'puma'
set :port, (ENV['PORT'] || 8580).to_i

get '/' do
  headers "Content-Type" => ""
  url = "https://dl.bintray.com/embulk/maven/"
  redirect to(url), 302
end

get '/embulk-latest.jar' do
  headers "Content-Type" => ""
  url = "https://dl.bintray.com/embulk/maven/embulk-#{get_latest_version}.jar"
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
