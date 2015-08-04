module Fluent
  require 'fluent/mixin/config_placeholders'

  class S3Output < Fluent::TimeSlicedOutput
    Fluent::Plugin.register_output('s3', self)

    def initialize
      super
      require 'aws-sdk-v1'
      require 'zlib'
      require 'time'
      require 'tempfile'

      @compressor = nil
    end

    config_param :path, :string, :default => ""
    config_param :use_ssl, :bool, :default => true
    config_param :use_server_side_encryption, :string, :default => nil
    config_param :aws_key_id, :string, :default => nil, :secret => true
    config_param :aws_sec_key, :string, :default => nil, :secret => true
    config_param :aws_iam_retries, :integer, :default => 5
    config_param :s3_bucket, :string
    config_param :s3_region, :string, :default => nil
    config_param :s3_endpoint, :string, :default => nil
    config_param :s3_object_key_format, :string, :default => "%{path}%{time_slice}_%{index}.%{file_extension}"
    config_param :store_as, :string, :default => "gzip"
    config_param :auto_create_bucket, :bool, :default => true
    config_param :check_apikey_on_start, :bool, :default => true
    config_param :proxy_uri, :string, :default => nil
    config_param :reduced_redundancy, :bool, :default => false
    config_param :format, :string, :default => 'out_file'
    config_param :acl, :string, :default => :private

    attr_reader :bucket

    include Fluent::Mixin::ConfigPlaceholders

    def placeholders
      [:percent]
    end

    def configure(conf)
      super

      if @s3_endpoint && @s3_endpoint.end_with?('amazonaws.com')
        raise ConfigError, "s3_endpoint parameter is not supported for S3, use s3_region instead. This parameter is for S3 compatible services"
      end

      begin
        @compressor = COMPRESSOR_REGISTRY.lookup(@store_as).new(:buffer_type => @buffer_type, :log => log)
      rescue => e
        $log.warn "#{@store_as} not found. Use 'text' instead"
        @compressor = TextCompressor.new
      end
      @compressor.configure(conf)

      # TODO: use Plugin.new_formatter instead of TextFormatter.create
      conf['format'] = @format
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
      elsif ENV.key? "AWS_ACCESS_KEY_ID"
        options[:credential_provider] = AWS::Core::CredentialProviders::ENVProvider.new('AWS')
      else
        options[:credential_provider] = AWS::Core::CredentialProviders::EC2Provider.new({:retries => @aws_iam_retries})
      end
      options[:region] = @s3_region if @s3_region
      options[:s3_endpoint] = @s3_endpoint if @s3_endpoint
      options[:proxy_uri] = @proxy_uri if @proxy_uri
      options[:use_ssl] = @use_ssl
      options[:s3_server_side_encryption] = @use_server_side_encryption.to_sym if @use_server_side_encryption

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
          "file_extension" => @compressor.ext,
          "index" => i,
          "uuid_flush" => uuid_random
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
        @compressor.compress(chunk, tmp)
        @bucket.objects[s3path].write(Pathname.new(tmp.path), {:content_type => @compressor.content_type,
                                                               :reduced_redundancy => @reduced_redundancy,
                                                               :acl => @acl})
      ensure
        tmp.close(true) rescue nil
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
    rescue AWS::S3::Errors::NoSuchBucket
      # ignore NoSuchBucket Error because ensure_bucket checks it.
    rescue => e
      raise "can't call S3 API. Please check your aws_key_id / aws_sec_key or s3_region configuration. error = #{e.inspect}"
    end

    class Compressor
      include Configurable

      def initialize(opts = {})
        super()
        @buffer_type = opts[:buffer_type]
        @log = opts[:log]
      end

      attr_reader :buffer_type, :log

      def configure(conf)
        super
      end

      def ext
      end

      def content_type
      end

      def compress(chunk, tmp)
      end

      private

      def check_command(command, algo = nil)
        require 'open3'

        algo = command if algo.nil?
        begin
          Open3.capture3("#{command} -V")
        rescue Errno::ENOENT
          raise ConfigError, "'#{command}' utility must be in PATH for #{algo} compression"
        end
      end
    end

    class GzipCompressor < Compressor
      def ext
        'gz'.freeze
      end

      def content_type
        'application/x-gzip'.freeze
      end

      def compress(chunk, tmp)
        w = Zlib::GzipWriter.new(tmp)
        chunk.write_to(w)
        w.close
      ensure
        w.close rescue nil
      end
    end

    class TextCompressor < Compressor
      def ext
        'txt'.freeze
      end

      def content_type
        'text/plain'.freeze
      end

      def compress(chunk, tmp)
        chunk.write_to(tmp)
        tmp.close
      end
    end

    class JsonCompressor < TextCompressor
      def ext
        'json'.freeze
      end

      def content_type
        'application/json'.freeze
      end
    end

    COMPRESSOR_REGISTRY = Registry.new(:s3_compressor_type, 'fluent/plugin/s3_compressor_')
    {
      'gzip' => GzipCompressor,
      'json' => JsonCompressor,
      'text' => TextCompressor
    }.each { |name, compressor|
      COMPRESSOR_REGISTRY.register(name, compressor)
    }

    def self.register_compressor(name, compressor)
      COMPRESSOR_REGISTRY.register(name, compressor)
    end
  end
end
