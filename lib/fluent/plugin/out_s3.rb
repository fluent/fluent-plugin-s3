module Fluent
  require 'fluent/mixin/config_placeholders'

  class S3Output < Fluent::TimeSlicedOutput
    Fluent::Plugin.register_output('s3', self)

    unless method_defined?(:log)
      define_method(:log) { $log }
    end

    def initialize
      super
      require 'aws-sdk'
      require 'zlib'
      require 'time'
      require 'tempfile'
      require 'open3'

      @use_ssl = true
    end

    config_param :path, :string, :default => ""

    config_param :aws_key_id, :string, :default => nil
    config_param :aws_sec_key, :string, :default => nil
    config_param :s3_bucket, :string
    config_param :s3_region, :string, :default => nil
    config_param :s3_endpoint, :string, :default => nil
    config_param :s3_object_key_format, :string, :default => "%{path}%{time_slice}_%{index}.%{file_extension}"
    config_param :store_as, :string, :default => "gzip"
    config_param :command_parameter, :string, :default => nil
    config_param :auto_create_bucket, :bool, :default => true
    config_param :check_apikey_on_start, :bool, :default => true
    config_param :proxy_uri, :string, :default => nil
    config_param :reduced_redundancy, :bool, :default => false
    config_param :format, :string, :default => 'out_file'

    attr_reader :bucket

    include Fluent::Mixin::ConfigPlaceholders

    def placeholders
      [:percent]
    end

    def configure(conf)
      super

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

      @ext, @mime_type = case @store_as
                         when 'gzip'
                           ['gz', 'application/x-gzip']
                         when 'lzo'
                           check_command('lzop', 'LZO')
                           @command_parameter = '-qf1' if @command_parameter.nil?
                           ['lzo', 'application/x-lzop']
                         when 'lzma2'
                           check_command('xz', 'LZMA2')
                           @command_parameter = '-qf0' if @command_parameter.nil?
                           ['xz', 'application/x-xz']
                         when 'json'
                           ['json', 'application/json']
                         else
                           ['txt', 'text/plain']
                         end

      if format_json = conf['format_json']
        $log.warn "format_json is deprecated. Use 'format json' instead"
        conf['format'] = 'json'
      else
        conf['format'] = @format
      end
      @formatter = TextFormatter.create(conf)

      if @localtime
        @path_slicer = Proc.new {|path|
          Time.now.strftime(path)
        }
      else
        @path_slicer = Proc.new {|path|
          Time.now.utc.strftime(path)
        }
      end
    end

    def start
      super
      options = {}
      if @aws_key_id && @aws_sec_key
        options[:access_key_id] = @aws_key_id
        options[:secret_access_key] = @aws_sec_key
      end
      options[:region] = @s3_region if @s3_region
      options[:endpoint] = @s3_endpoint if @s3_endpoint
      options[:proxy_uri] = @proxy_uri if @proxy_uri
      options[:use_ssl] = @use_ssl

      @s3 = AWS::S3.new(options)
      @bucket = @s3.buckets[@s3_bucket]

      check_apikeys if @check_apikey_on_start
      ensure_bucket
    end

    def format(tag, time, record)
      @formatter.format(tag, time, record)
    end

    def write(chunk)
      i = 0
      previous_path = nil

      begin
        path = @path_slicer.call(@path)
        values_for_s3_object_key = {
          "path" => path,
          "time_slice" => chunk.key,
          "file_extension" => @ext,
          "index" => i
        }
        s3path = @s3_object_key_format.gsub(%r(%{[^}]+})) { |expr|
          values_for_s3_object_key[expr[2...expr.size-1]]
        }
        if (i > 0) && (s3path == previous_path)
          raise "duplicated path is generated. use %{index} in s3_object_key_format: path = #{s3path}"
        end

        i += 1
        previous_path = s3path
      end while @bucket.objects[s3path].exists?

      tmp = Tempfile.new("s3-")
      begin
        if @store_as == "gzip"
          w = Zlib::GzipWriter.new(tmp)
          chunk.write_to(w)
          w.close
        elsif @store_as == "lzo"
          w = Tempfile.new("chunk-tmp")
          chunk.write_to(w)
          w.close
          tmp.close
          # We don't check the return code because we can't recover lzop failure.
          system "lzop #{@command_parameter} -o #{tmp.path} #{w.path}"
        elsif @store_as == "lzma2"
          w = Tempfile.new("chunk-xz-tmp")
          chunk.write_to(w)
          w.close
          tmp.close
          system "xz #{@command_parameter} -c #{w.path} > #{tmp.path}"
        else
          chunk.write_to(tmp)
          tmp.close
        end
        @bucket.objects[s3path].write(Pathname.new(tmp.path), {:content_type => @mime_type,
                                                               :reduced_redundancy => @reduced_redundancy})
      ensure
        tmp.close(true) rescue nil
        w.close rescue nil
        w.unlink rescue nil
      end
    end

    private

    def ensure_bucket
      if !@bucket.exists?
        if @auto_create_bucket
          log.info "Creating bucket #{@s3_bucket} on #{@s3_endpoint}"
          @s3.buckets.create(@s3_bucket)
        else
          raise "The specified bucket does not exist: bucket = #{@s3_bucket}"
        end
      end
    end

    def check_apikeys
      @bucket.empty?
    rescue
      raise "can't call S3 API. Please check your aws_key_id / aws_sec_key or s3_region configuration"
    end

    def check_command(command, algo)
      begin
        Open3.capture3("#{command} -V")
      rescue Errno::ENOENT
        raise ConfigError, "'#{command}' utility must be in PATH for #{algo} compression"
      end
    end
  end
end
