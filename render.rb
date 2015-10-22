require 'logger'
require 'faraday'
require 'httpclient'
require 'oj'
require 'parallel'
require 'erb'
require 'cgi'
require 'git'
require 'fileutils'

class PluginListRenderer
  def initialize(log)
    @log = log
    Faraday.default_adapter = :httpclient
  end

  GEM_KEYS = [:name, :authors, :version, :licenses, :downloads, :info]
  GEM_DOC_URL_KEYS = [:project_uri, :source_code_uri, :homepage_uri, :documentation_uri]
  GITHUB_KEYS = [:stargazers_count]
  GITHUB_OWNER_KEYS = [:avatar_url]

  CATEGORIES = %w[input output filter guess parser decoder formatter encoder executor]
  FOR_FILE_CATEGORIES = %w[parser decoder formatter encoder]

  def search_gems
    @log.info "Searching embulk gems..."

    gems = []
    used = {}

    rubygems_org = Faraday.new('https://rubygems.org')
    (1..100).each do |i|
      res = rubygems_org.get("/api/v1/search.json?query=embulk-&page=#{i}")
      raise "RubyGems.org search failed #{res.status} #{res.body}" if res.status != 200

      json = Oj.load(res.body)
      json.each do |gem_json|
        next if used[gem_json["name"]]
        used[gem_json["name"]] = true

        gem = {}
        GEM_KEYS.each {|key| gem[key] = gem_json[key.to_s] }
        GEM_DOC_URL_KEYS.each do |k|
          if url = gem_json[k.to_s]
            gem[:github_url] = url if url =~ /github.com/ && url.count("/") == 4
          end
        end
        gem_name = gem[:gem_name] = gem[:name]
        gem[:url] = gem[:github_url] || "http://rubygems.org/gems/#{gem_name}"
        m = gem_name.match(/^embulk-(input|output|filter|guess|encoder|decoder|formatter|parser|executor)-(.*)$/)
        next unless m
        gem[:category] = m[1]
        gem[:name] = m[2]

        gems << gem
      end

      break if json.empty? || json.size < 10
    end

    return gems
  end

  def add_github_keys(gems)
    Parallel.each(gems, in_threads: 2) do |gem|
      url = gem[:github_url]
      next unless url

      m = url.match(/github.com\/([^\/]+)\/([^\/]+)/)
      next unless m

      owner, repo = m[1], m[2]
      gem[:owner] = owner
      gem[:repo] = repo

      github_com = (Thread.current[:http] ||= Faraday.new('https://api.github.com'))
      res = github_com.get("/repos/#{owner}/#{repo}")
      next if res.status != 200  # TODO don't ignore if the cause is rate limit

      json = Oj.load(res.body)
      GITHUB_KEYS.each {|key| gem[key] = json[key.to_s] }

      owner_json = (json['owner'] || {})
      GITHUB_OWNER_KEYS.each {|key| gem[key] = owner_json[key.to_s] }
    end

    gems
  end

  def render(erb)
    # older repository first for deterministic display
    gems = search_gems
    add_github_keys(gems)

    gems = gems.sort_by {|gem| ((gem[:downloads] || 0) << 16) | (gem[:stargazers_count] || 0) }.reverse

    # cleanup
    gems.each do |gem|
      gem[:stargazers_count] ||= "-"
      gem[:author] = Array(gem[:authors] || []).join(', ')
    end

    categories = gems
      .group_by {|gem| cate = gem[:category] }
      .to_a
      .sort_by {|category,gems| CATEGORIES.index(category) }
      .map do |category,gems|
        if FOR_FILE_CATEGORIES.include?(category)
          category = "file #{category}"
        end
        [category, gems]
      end

    return ERB.new(erb).result(binding)
  end

  def e(s)
    CGI.escape(s.to_s)
  end

  def h(s)
    CGI.escape_html(s.to_s)
  end
end

def update_index(log)
  # clone repository
  repo_dir = File.expand_path("tmp/gh-pages")
  credentials_path = "#{ENV['HOME']}/.git_credentials"

  retry_count = 0
  begin
    File.open('Gemfile') {|f| f.flock(File::LOCK_EX) }

    if Dir.exists?(repo_dir)
      log.info "Using cached local git repository..."
      git = Git.open(repo_dir)
    else
      log.info "Cloning remote git repository..."
      FileUtils.mkdir_p(repo_dir)
      git = Git.clone("https://github.com/embulk/embulk.github.io",
                      File.basename(repo_dir), path: File.dirname(repo_dir))
    end

    git.config("user.name", "embulk.org plugin list updator on heroku")
    git.config("user.email", "heroku@embulk.org")
    git.config("credential.helper", "store --file=#{credentials_path}")

    log.info "Merging the latest files..."
    log.info git.remote("origin").fetch

    log.info git.branch("master").checkout
    log.info git.remote("origin").merge("master")

    current_commit = git.object('HEAD').sha

    erb = File.read("#{repo_dir}/plugins/index.html.erb")
    html = PluginListRenderer.new(log).render(erb)
    File.write("#{repo_dir}/plugins/index.html", html)

    git.add("#{repo_dir}/plugins/index.html")
    git.commit("updated plugins/index.html") rescue nil

    next_commit = git.object('HEAD').sha

    if current_commit == next_commit
      log.info "Not changed."
    else
      log.info "Pushing changes to remote repository..."
      File.write(credentials_path, "https://#{ENV['GITHUB_TOKEN']}:@github.com")
      begin
        log.info git.push("origin", "master")
      ensure
        FileUtils.rm_f credentials_path
      end
    end

    log.info "Done."

  rescue => e
    raise if retry_count >= 1
    log.info "Retrying: #{e}"

    # delete repo_dir and retry
    FileUtils.rm_rf repo_dir
    FileUtils.mkdir_p File.dirname(repo_dir)
    retry_count += 1
    retry
  end
end

update_index(Logger.new(STDOUT)) if __FILE__ == $0

