module Fluent


class S3Output < Fluent::TimeSlicedOutput
  Fluent::Plugin.register_output('s3', self)

  def initialize
    super
    require 'aws-sdk'
    require 'zlib'
    require 'time'
  end

  def configure(conf)
    super

    if aws_key_id = conf['aws_key_id']
      @aws_key_id = aws_key_id
    end
    unless @aws_key_id
      raise ConfigError, "'aws_key_id' parameter is required on file output"
    end

    if aws_sec_key = conf['aws_sec_key']
      @aws_sec_key = aws_sec_key
    end
    unless @aws_sec_key
      raise ConfigError, "'aws_sec_key' parameter is required on file output"
    end

    if s3_bucket = conf['s3_bucket']
      @s3_bucket = s3_bucket
    end
    unless @s3_bucket
      raise ConfigError, "'s3_bucket' parameter is required on file output"
    end

    if path = conf['path']
      @path = path
    end
    unless @path
      raise ConfigError, "'path' parameter is required on file output"
    end

    if @localtime
      @formatter = Proc.new {|tag,event|
        "#{Time.at(event.time).iso8601}\t#{tag}\t#{event.record.to_json}\n"
      }
    else
      @formatter = Proc.new {|tag,event|
        "#{Time.at(event.time).utc.iso8601}\t#{tag}\t#{event.record.to_json}\n"
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

  def format(tag, event)
    @formatter.call(tag, event)
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

