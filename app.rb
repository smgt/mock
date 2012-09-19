require "bundler/setup"
require "sinatra/base"
require "sinatra/reloader"
require "dropbox_sdk"
require "cgi"
require "base64"
require "cloudinary"
require "redis"

module Mock

  class Application < Sinatra::Base

    configure do
      uri = URI.parse(ENV["REDISTOGO_URL"]||="redis://localhost:6379")
      REDIS = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
    end

    helpers do
      def h(string)
        CGI.escapeHTML(string)
      end

      def thumbnail_src(dropbox_path)
        image_id = REDIS.get "thumb:"+dropbox_path
        if image_id
          url = REDIS.get "cloudinary:"+image_id+":url"
          return Cloudinary::Utils.cloudinary_url(url.split("/").last, :width => 64, :height => 64, :crop => :thumb )
        else
          return "/thumb/"+CGI.escape(dropbox_path)
        end
      end
    end

    register Sinatra::Reloader
    enable :session
    enable :logging


    get "/thumb/*" do
      path = params[:splat].first.gsub("+", " ")
      thumb_key = "thumb:"+path

      @dropbox = Dropbox.new
      begin
        thumb_raw = @dropbox.thumbnail(path, "l")
        logger.info "After error"
        thumb_base64 = "data:image/jpeg;base64,"+Base64.encode64(thumb_raw)
        cloud_image = Cloudinary::Uploader.upload(thumb_base64)
        if cloud_image
          REDIS.set "thumb:"+path, cloud_image["public_id"]
          REDIS.set "cloudinary:"+cloud_image["public_id"]+":url", cloud_image["url"]
        end
        content_type "image/jpeg"
        return @dropbox.thumbnail(path, "s")
      rescue DropboxError => e
        logger.info e
        redirect to("/img/placeholder64.png"), 302
      end
    end

    get "/image/*" do
      path = params[:splat].first.gsub("+", " ")
      if path
        @dropbox = Dropbox.new
        @media = @dropbox.media(path)
        @path = path
        erb :file
      else
        halt 404
      end
    end

    get "/auth" do
      db = DropboxSession.new(DROPBOX_CONSUMER_KEY, DROPBOX_CONSUMER_SECRET)
      db.get_request_token
      authorize_url = db.get_authorize_url("http://localhost:9292/callback")
      session[:dropbox] = db.serialize
      file = File.open("dropbox.yml", "w")
      file << db.serialize
      file.close
      redirect to authorize_url
    end

    get "/callback" do
      f = File.open("dropbox.yml", "r+")
      dropbox_session = f.readlines.join
      logger.info dropbox_session.inspect
      db = DropboxSession.deserialize(dropbox_session)
      @access_token = db.get_access_token
      f.rewind
      f << db.serialize
      f.close
      redirect to "/"
    end

    # Since we are doing a splat on / this needs to be at the end
    get "/*" do
      path = params["path"] || "/"
      @dropbox = Dropbox.new
      if !@dropbox.session
        redirect to "/auth"
      end
      @files = @dropbox.metadata(path)
      erb :index
    end

  end

  class Dropbox

    BASE_PATH="/Mock Webgallery"

    attr_reader :session, :client

    def initialize
      @session = Dropbox.create_session
      if @session
        @client = DropboxClient.new(@session, :dropbox)
      end
    end

    def self.create_session
      if ENV['DROPBOX_CONSUMER_KEY'] && ENV['DROPBOX_CONSUMER_SECRET'] && ENV['DROPBOX_REQUEST_TOKEN'] && ENV['DROPBOX_REQUEST_SECRET'] && ENV['DROPBOX_ACCESS_TOKEN'] && ENV['DROPBOX_ACCESS_TOKEN_SECRET']
        ser = [
          ENV['DROPBOX_ACCESS_TOKEN_SECRET'],
          ENV['DROPBOX_ACCESS_TOKEN'],
          ENV['DROPBOX_REQUEST_SECRET'],
          ENV['DROPBOX_REQUEST_TOKEN'],
          ENV['DROPBOX_CONSUMER_SECRET'],
          ENV['DROPBOX_CONSUMER_KEY']
        ]
      elsif File.exists?("dropbox.yml")
        file = File.open("dropbox.yml", "r")
        ser = YAML::load(file)
        file.close
      else
        return false
      end

      session = DropboxSession.new(ser.pop, ser.pop)
      session.set_request_token(ser.pop, ser.pop)

      if ser.length > 0
        session.set_access_token(ser.pop, ser.pop)
      end

      return session
    end

    def authorized?
      @session.authorized?
    end

    def thumbnail(from_path, size="large")
      @client.thumbnail(BASE_PATH+from_path, size)
    end

    def media(path)
      media = @client.media(BASE_PATH+path)
      return media
    end

    def metadata(path, file_limit=25000, list=true, hash=nil, rev=nil, include_deleted=false)
      metadata = @client.metadata(BASE_PATH+path, file_limit, list, hash, rev, include_deleted)
      contents = Array.new
      metadata['contents'].each do |file|
        file['path'] = file['path'][(BASE_PATH.length)..(file['path'].length-1)] if file['path'].start_with? BASE_PATH
        contents << file
      end
      metadata['contents'] = contents
      return metadata
    end

  end


end
