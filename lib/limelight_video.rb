require 'faraday'
require 'json'
require 'base64'
require 'openssl'
require 'tempfile'
require 'mime/types'

class Limelight
  def initialize(options = {})
    @organization = options.fetch(:organization, ENV['LIMELIGHT_ORGANIZATION'])
    raise KeyError.new("organization") if !@organization

    @access_key = options.fetch(:access_key, ENV['LIMELIGHT_ACCESS_KEY'])
    @secret = options.fetch(:secret, ENV['LIMELIGHT_SECRET'])

    @host = 'http://api.videoplatform.limelight.com'
    @analytics_host = 'http://api.delvenetworks.com/rest/'

    @base_url = "/rest/organizations/#{@organization}"

    @base_media_url = "#{@base_url}/media"
    @base_channels_url = "#{@base_url}/channels"
    @base_analytics_url = "#{@base_url}/analytics"

    @client = Faraday.new(@host) do |builder|
      builder.request :multipart
      builder.request :url_encoded
      builder.adapter :net_http
    end

    @analytics_client = Faraday.new(@analytics_host) do |builder|
      builder.request :multipart
      builder.request :url_encoded
      builder.adapter :net_http
    end
  end

  def media_info(media_id)
    response = @client.get("#{@base_media_url}/#{media_id}/properties.json")
    JSON.parse response.body
  end


  # valid primary_use values are :all, :flash, :mobile264, :mobile3gp, :httplivestreaming
  # default value is :all
  def media_encodings(id, primary_use = :all)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/media/<media id>/encodings.{XML,JSON}
    params = {:primary_use => primary_use.to_s}

    path = generate_encoded_path('get', "#{@base_media_url}/#{id}/encodings.json", params)
    response = @client.get(path, params)
    JSON.parse response.body
  end

  def update_media(id, attributes)
    path = generate_encoded_path('put', "#{@base_media_url}/#{id}/properties")
    response = @client.put(path, attributes)

    JSON.parse response.body
  end

  def analytics_for_media(*id)
    # http://api.delvenetworks.com/rest/organizations/<org id>/analytics/report/media.{xml,json,csv}
    path = generate_encoded_path('get', "#{@base_analytics_url}/report/media.json", {
      media_id: id.join(',')
    }, @analytics_host)
    response = @analytics_client.get(path)
    JSON.parse response.body
  end

  def analytics_for_channels(start_time, end_time, options = {})
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/analytics/performance/channels.{xml,json,csv}
    params = {
      :start => start_time,
      :end => end_time
    }

    params.merge!(options)

    path = generate_encoded_path('get', "#{@base_analytics_url}/performance/channels.json", params, @host)
    response = @client.get(path)
    JSON.parse response.body
  end

  def media_engagement(start_time, end_time, options = {})
    params = {
      :start => start_time,
      :end => end_time
    }

    params.merge!(options)

    path = generate_encoded_path('get', "#{@base_analytics_url}/engagement/media.json", params, @host)

    response = @client.get(path)
    JSON.parse response.body
  end

  def most_played_media(start_time, end_time, options = {})
    params = {
      :start => start_time,
      :end => end_time
    }

    params.merge!(options)

    path = generate_encoded_path('get', "#{@base_analytics_url}/performance/media.json", params, @host)

    response = @client.get(path)
    JSON.parse response.body
  end

  def upload(filename_or_io, attributes = {})
    case filename_or_io
      when String
        file = File.open(filename_or_io)
        filename = filename_or_io
        mime = MIME::Types.of(filename_or_io)
      when Tempfile, StringIO
        file = filename_or_io
        filename = attributes.fetch(:filename)
        mime = attributes[:type] || MIME::Types.of(filename)
      else
        raise Errno::ENOENT
      end

    media_file = Faraday::UploadIO.new(file, mime, filename)
    options = {
      title: attributes.fetch(:title, 'Unnamed'),
      media_file: media_file
    }
    if attributes[:metadata]
      custom_properties = attributes[:metadata]
      properties_to_create = custom_properties.keys.map(&:to_s) - list_metadata
      create_metadata(properties_to_create)
    end

    options[:custom_property] = attributes.fetch(:metadata, {})
    response = @client.post(upload_path, options) do |req|
      req.options[:open_timeout] = 60*60
    end

    JSON.parse response.body
  end

  def upload_url
    @host + upload_path
  end

  def upload_path
    generate_encoded_path('post', @base_media_url)
  end

  def create_channel(name)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/channels.{XML,JSON}
    path = generate_encoded_path('post', @base_channels_url)
    response = @client.post(path, title: name)

    JSON.parse response.body
  end

  def publish_channel(id)
    update_channel id, state: "Published"
  end

  def update_channel(id, properties)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/channels/<channel id>/properties.{XML,JSON}
    # see http://www.limelightvideoplatform.com/support/docs/#2.2 for properties
    path = generate_encoded_path('put', "#{@base_channels_url}/#{id}/properties")
    response = @client.put(path, properties)

    JSON.parse response.body
  end

  def delete_channel(channel_id)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/channels/<channel id>
    path = generate_encoded_path('delete', "#{@base_channels_url}/#{channel_id}")
    @client.delete(path)
  end

  def create_metadata(names)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/media/properties/custom/<property name>
    Array(names).each do |name|
      path = generate_encoded_path('put', "#{@base_media_url}/properties/custom/#{name}")
      @client.put(path)
    end
  end

  def list_metadata
    # http://api.videoplatform.limelight.com/rest/organizations/<orgid>/media/properties/custom.{XML,JSON}
    response = @client.get("#{@base_media_url}/properties/custom.json")
    metadata = JSON.parse response.body
    metadata["custom_property_types"].map { |meta| meta["type_name"] }
  end

  def remove_metadata(names)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/media/properties/custom/<property name>
    Array(names).each do |name|
      path = generate_encoded_path('delete', "#{@base_media_url}/properties/custom/#{name}")
      @client.delete(path)
    end
  end

  def delete_media(media_id)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/media/<media id>
    path = generate_encoded_path('delete', "#{@base_media_url}/#{media_id}")
    @client.delete(path)
  end

  def add_media_to_a_channel(media_id, channel_id)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/channels/<channel id>/media/<media id>
    path = generate_encoded_path('put', "#{@base_channels_url}/#{channel_id}/media/#{media_id}")
    response = @client.put(path)
  end

  def delete_media_from_channel(media_id, channel_id)
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/channels/<channel id>/media/<media id>
    path = generate_encoded_path('delete', "#{@base_channels_url}/#{channel_id}/media/#{media_id}")
    @client.delete(path)
  end

  def list_channel_media(channel_id, options = {})
    # http://api.videoplatform.limelight.com/rest/organizations/<org id>/channels/<channel id>/media.{XML,JSON}
    response = @client.get("#{@base_channels_url}/#{channel_id}/media.json", options)
    JSON.parse response.body
  end

  private

  def generate_encoded_path(method = 'get', path = @base_media_url, params = {}, host = @host)
    authorized_action

    params.merge!(access_key: @access_key, expires: Time.now.to_i + 300)
    signed = payload(params, method, path, host)
    signature = Base64.encode64(OpenSSL::HMAC.digest('sha256', @secret, signed))
    params[:signature] = signature.chomp

    "#{path}?#{Faraday::Utils.build_query(Hash[params.sort])}"
  end

  def authorized_action
    raise KeyError.new("secret")     if !@secret
    raise KeyError.new("access_key") if !@access_key
  end

  def payload(params, method = 'get', path = @base_url, host = @host)
    [
      method.downcase, URI.parse(host).host, path,
      params.sort.map{ |arr| arr.join('=') }.join('&')
    ].join('|')
  end
end
