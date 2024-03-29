require "bundler/setup"
require "sinatra/base"
require "sinatra/reloader" if development?
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
      #enable :session
      enable :logging
    end

    configure :development do
      register Sinatra::Reloader
    end

    helpers do
      def h(string)
        CGI.escapeHTML(string)
      end

      def thumbnail_src(dropbox_path)
        image_id = REDIS.get "thumb:"+dropbox_path
        if image_id
          url = REDIS.get "cloudinary:"+image_id+":url"
          return Cloudinary::Utils.cloudinary_url(url.split("/").last, :width => 128, :height => 128, :crop => :thumb )
        else
          return "/thumb/"+CGI.escape(dropbox_path)
        end
      end

      def image_src(dropbox_path)
        image_id = REDIS.get "thumb:"+dropbox_path
        if image_id
          url = REDIS.get "cloudinary:"+image_id+":url"
          return Cloudinary::Utils.cloudinary_url(url.split("/").last, :width => 700, :height => 700, :crop => :fit, :quality => 90)
        else
          return "/thumb/"+CGI.escape(dropbox_path)
        end
      end
    end

    get "/thumb/*" do
      path = params[:splat].first.gsub("+", " ")
      thumb_key = "thumb:"+path

      begin
        @dropbox = Dropbox.new
        thumb_raw = @dropbox.thumbnail(path, "xl")
        thumb_base64 = "data:image/jpeg;base64,"+Base64.encode64(thumb_raw)
        cloud_image = Cloudinary::Uploader.upload(thumb_base64, :tags => [ENV["RACK_ENV"]])
        if cloud_image
          REDIS.set "thumb:"+path, cloud_image["public_id"]
          REDIS.set "cloudinary:"+cloud_image["public_id"]+":url", cloud_image["url"]
        end
        content_type "image/jpeg"
        return @dropbox.thumbnail(path, "m")
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
        erb :image
      else
        halt 404
      end
    end

    # Move /auth and /callback into a rake task
    #
    # get "/auth" do
    #   db = DropboxSession.new(DROPBOX_CONSUMER_KEY, DROPBOX_CONSUMER_SECRET)
    #   db.get_request_token
    #   authorize_url = db.get_authorize_url("http://localhost:9292/callback")
    #   session[:dropbox] = db.serialize
    #   file = File.open("dropbox.yml", "w")
    #   file << db.serialize
    #   file.close
    #   redirect to authorize_url
    # end

    # get "/callback" do
    #   f = File.open("dropbox.yml", "r+")
    #   dropbox_session = f.readlines.join
    #   logger.info dropbox_session.inspect
    #   db = DropboxSession.deserialize(dropbox_session)
    #   @access_token = db.get_access_token
    #   f.rewind
    #   f << db.serialize
    #   f.close
    #   redirect to "/"
    # end

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
      @client.thumbnail(ENV['DROPBOX_BASE_PATH']+from_path, size)
    end

    def media(path)
      media = @client.media(ENV['DROPBOX_BASE_PATH']+path)
      return media
    end

    def metadata(path, file_limit=25000, list=true, hash=nil, rev=nil, include_deleted=false)
      metadata = @client.metadata(ENV['DROPBOX_BASE_PATH']+path, file_limit, list, hash, rev, include_deleted)
      contents = Array.new
      metadata['contents'].each do |file|
        file['path'] = file['path'][(ENV['DROPBOX_BASE_PATH'].length)..(file['path'].length-1)] if file['path'].start_with? ENV['DROPBOX_BASE_PATH']
        contents << file
      end
      metadata['contents'] = contents
      return metadata
    end

  end


end
