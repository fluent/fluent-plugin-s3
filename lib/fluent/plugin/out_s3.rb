module Fluent


class S3Output < Fluent::TimeSlicedOutput
  Fluent::Plugin.register_output('s3', self)

  def initialize
    super
    require 'aws-sdk'
    require 'zlib'
    require 'time'
  end

  attr_accessor :aws_key_id, :aws_sec_key, :s3_bucket, :path

  def configure(conf)
    super

    if aws_key_id = conf['aws_key_id']
      @aws_key_id = aws_key_id
    end
    unless @aws_key_id
      raise ConfigError, "'aws_key_id' parameter is required on s3 output"
    end

    if aws_sec_key = conf['aws_sec_key']
      @aws_sec_key = aws_sec_key
    end
    unless @aws_sec_key
      raise ConfigError, "'aws_sec_key' parameter is required on s3 output"
    end

    if s3_bucket = conf['s3_bucket']
      @s3_bucket = s3_bucket
    end
    unless @s3_bucket
      raise ConfigError, "'s3_bucket' parameter is required on s3 output"
    end

    if path = conf['path']
      @path = path
    end
    unless @path
      @path = ''
    end

    if @localtime
      @formatter = Proc.new {|tag,time,record|
        "#{Time.at(time).iso8601}\t#{tag}\t#{record.to_json}\n"
      }
    else
      @formatter = Proc.new {|tag,time,record|
        "#{Time.at(time).utc.iso8601}\t#{tag}\t#{record.to_json}\n"
      }
    end
  end

  def start
    super
    @s3 = AWS::S3.new(
      :access_key_id=>@aws_key_id,
      :secret_access_key=>@aws_sec_key)
    @bucket = @s3.buckets[@s3_bucket]
  end

  def format(tag, time, record)
    @formatter.call(tag, time, record)
  end

  def write(chunk)
    s3path = "#{@path}#{chunk.key}.gz"

    tmp = Tempfile.new("s3-")
    w = Zlib::GzipWriter.new(tmp)
    begin
      chunk.write_to(w)
      w.finish
      @bucket.objects[s3path].write(Pathname.new(tmp.path))
    ensure
      w.close rescue nil
    end
  end
end


end

