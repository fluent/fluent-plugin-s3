module Fluent


class S3Output < Fluent::TimeSlicedOutput
  Fluent::Plugin.register_output('s3', self)

  def initialize
    super
    require 'aws-sdk'
    require 'zlib'
    require 'time'
    require 'tempfile'

    @use_ssl = true
  end

  config_param :path, :string, :default => ""
  config_param :time_format, :string, :default => nil

  include SetTagKeyMixin
  config_set_default :include_tag_key, false

  include SetTimeKeyMixin
  config_set_default :include_time_key, false

  config_param :aws_key_id, :string, :default => nil
  config_param :aws_sec_key, :string, :default => nil
  config_param :s3_bucket, :string
  config_param :s3_endpoint, :string, :default => nil
  config_param :s3_object_key_format, :string, :default => "%{path}%{time_slice}_%{index}.%{file_extension}"
  config_param :output_data_type, :string, :default => 'json'
  config_param :include_tag_and_time, :bool, :default => true

  attr_reader :bucket

  def configure(conf)
    super

    if format_json = conf['format_json']
      @include_tag_and_time = false
      @output_data_type = 'json'
    end

    if @output_data_type == 'ltsv'
      begin
        require 'ltsv'
      rescue LoadError
        raise ConfigError, "You must install ltsv.gem to use 'ltsv' for output_data_type option on s3 output"
      end
    end
    @dumper =
      case @output_data_type
      when 'json'
        Yajl.method(:dump)
      when 'ltsv'
        LTSV.method(:dump)
      else
        raise ConfigError, "Currently only 'json' and 'ltsv' are supported for output_data_type option on s3 output"
      end

    if use_ssl = conf['use_ssl']
      if use_ssl.empty?
        @use_ssl = true
      else
        @use_ssl = Config.bool_value(use_ssl)
        if @use_ssl.nil?
          raise ConfigError, "'true' or 'false' is required for use_ssl option on s3 output"
        end
      end
    end

    @timef = TimeFormatter.new(@time_format, @localtime)
  end

  def start
    super
    options = {}
    if @aws_key_id && @aws_sec_key
      options[:access_key_id] = @aws_key_id
      options[:secret_access_key] = @aws_sec_key
    end
    options[:s3_endpoint] = @s3_endpoint if @s3_endpoint
    options[:use_ssl] = @use_ssl

    @s3 = AWS::S3.new(options)
    @bucket = @s3.buckets[@s3_bucket]
  end

  def format(tag, time, record)
    if @include_time_key || @include_tag_and_time
      time_str = @timef.format(time)
    end

    # copied from each mixin because current TimeSlicedOutput can't support mixins.
    if @include_tag_key
      record[@tag_key] = tag
    end
    if @include_time_key
      record[@time_key] = time_str
    end

    data = @dumper.call(record)

    tag_and_time = "#{time_str}\t#{tag}\t" if @include_tag_and_time
    "#{tag_and_time}#{data}\n"
  end

  def write(chunk)
    i = 0
    begin
      values_for_s3_object_key = {
        "path" => @path,
        "time_slice" => chunk.key,
        "file_extension" => "gz",
        "index" => i
      }
      s3path = @s3_object_key_format.gsub(%r(%{[^}]+})) { |expr|
        values_for_s3_object_key[expr[2...expr.size-1]]
      }
      i += 1
    end while @bucket.objects[s3path].exists?

    tmp = Tempfile.new("s3-")
    w = Zlib::GzipWriter.new(tmp)
    begin
      chunk.write_to(w)
      w.close
      @bucket.objects[s3path].write(Pathname.new(tmp.path), :content_type => 'application/x-gzip')
    ensure
      tmp.close(true) rescue nil
      w.close rescue nil
    end
  end
end


end

