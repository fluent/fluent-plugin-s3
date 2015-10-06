module Fluent
  require 'fluent/mixin/config_placeholders'

  class S3Output < Fluent::TimeSlicedOutput
    Fluent::Plugin.register_output('s3', self)

    def initialize
      super
      require 'aws-sdk-resources'
      require 'zlib'
      require 'time'
      require 'tempfile'

      @compressor = nil
    end

    config_param :path, :string, :default => ""
    config_param :use_server_side_encryption, :string, :default => nil
    config_param :aws_key_id, :string, :default => nil, :secret => true
    config_param :aws_sec_key, :string, :default => nil, :secret => true
    config_section :assume_role_credentials, :multi => false do
      config_param :role_arn, :string
      config_param :role_session_name, :string
      config_param :policy, :string, :default => nil
      config_param :duration_seconds, :integer, :default => nil
      config_param :external_id, :string, :default => nil
    end
    config_section :instance_profile_credentials, :multi => false do
      config_param :retries, :integer, :default => nil
      config_param :ip_address, :string, :default => nil
      config_param :port, :integer, :default => nil
      config_param :http_open_timeout, :float, :default => nil
      config_param :http_read_timeout, :float, :default => nil
      # config_param :delay, :integer or :proc, :default => nil
      # config_param :http_degub_output, :io, :default => nil
    end
    config_section :shared_credentials, :multi => false do
      config_param :path, :string, :default => nil
      config_param :profile_name, :string, :default => nil
    end
    config_param :aws_iam_retries, :integer, :default => 5
    config_param :s3_bucket, :string
    config_param :s3_region, :string, :default => ENV["AWS_REGION"] || "us-east-1"
    config_param :s3_endpoint, :string, :default => nil
    config_param :s3_object_key_format, :string, :default => "%{path}%{time_slice}_%{index}.%{file_extension}"
    config_param :force_path_style, :bool, :default => false
    config_param :store_as, :string, :default => "gzip"
    config_param :auto_create_bucket, :bool, :default => true
    config_param :check_apikey_on_start, :bool, :default => true
    config_param :proxy_uri, :string, :default => nil
    config_param :reduced_redundancy, :bool, :default => false
    config_param :storage_class, :string, :default => "STANDARD"
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
      rescue
        $log.warn "#{@store_as} not found. Use 'text' instead"
        @compressor = TextCompressor.new
      end
      @compressor.configure(conf)

      @formatter = Plugin.new_formatter(@format)
      @formatter.configure(conf)

      if @localtime
        @path_slicer = Proc.new {|path|
          Time.now.strftime(path)
        }
      else
        @path_slicer = Proc.new {|path|
          Time.now.utc.strftime(path)
        }
      end

      @storage_class = "REDUCED_REDUNDANCY" if @reduced_redundancy
    end

    def start
      super
      options = setup_credentials
      options[:region] = @s3_region if @s3_region
      options[:endpoint] = @s3_endpoint if @s3_endpoint
      options[:http_proxy] = @proxy_uri if @proxy_uri
      options[:s3_server_side_encryption] = @use_server_side_encryption.to_sym if @use_server_side_encryption
      options[:force_path_style] = @force_path_style

      s3_client = Aws::S3::Client.new(options)
      @s3 = Aws::S3::Resource.new(:client => s3_client)
      @bucket = @s3.bucket(@s3_bucket)

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
      end while @bucket.object(s3path).exists?

      tmp = Tempfile.new("s3-")
      begin
        @compressor.compress(chunk, tmp)
        tmp.rewind
        @bucket.object(s3path).put(:body => tmp,
                                   :content_type => @compressor.content_type,
                                   :storage_class => @storage_class)
      ensure
        tmp.close(true) rescue nil
      end
    end

    private

    def ensure_bucket
      if !@bucket.exists?
        if @auto_create_bucket
          log.info "Creating bucket #{@s3_bucket} on #{@s3_endpoint}"
          @s3.create_bucket(:bucket => @s3_bucket)
        else
          raise "The specified bucket does not exist: bucket = #{@s3_bucket}"
        end
      end
    end

    def check_apikeys
      @bucket.objects.first
    rescue Aws::S3::Errors::NoSuchBucket
      # ignore NoSuchBucket Error because ensure_bucket checks it.
    rescue => e
      raise "can't call S3 API. Please check your aws_key_id / aws_sec_key or s3_region configuration. error = #{e.inspect}"
    end

    def setup_credentials
      options = {}
      credentials_options = {}
      case
      when @aws_key_id && @aws_sec_key
        options[:access_key_id] = @aws_key_id
        options[:secret_access_key] = @aws_sec_key
      when @assume_role_credentials
        c = @assume_role_credentials
        credentials_options[:role_arn] = c.role_arn
        credentials_options[:role_session_name] = c.role_session_name
        credentials_options[:policy] = c.policy if c.policy
        credentials_options[:duration_seconds] = c.duration_seconds if c.duration_seconds
        credentials_options[:external_id] = c.external_id if c.external_id
        options[:credentials] = Aws::AssumeRoleCredentials.new(credentials_options)
      when @instance_profile_credentials
        c = @instance_profile_credentials
        credentials_options[:retries] = c.retries if c.retries
        credentials_options[:ip_address] = c.ip_address if c.ip_address
        credentials_options[:port] = c.port if c.port
        credentials_options[:http_open_timeout] = c.http_open_timeout if c.http_open_timeout
        credentials_options[:http_read_timeout] = c.http_read_timeout if c.http_read_timeout
        options[:credentials] = Aws::InstanceProfileCredentials.new(credentials_options)
      when @shared_credentials
        c = @shared_credentials
        credentials_options[:path] = c.path if c.path
        credentials_options[:profile_name] = c.profile_name if c.profile_name
        options[:credentials] = Aws::SharedCredentials.new(credentials_options)
      when @aws_iam_retries
        $log.warn("'aws_iam_retries' parameter is deprecated. Use 'instance_profile_credentials' instead")
        credentials_options[:retries] = @aws_iam_retries
        options[:credentials] = Aws::InstanceProfileCredentials.new(credentials_options)
      else
        # Use default credentials
        # See http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Client.html
      end
      options
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
        w.finish
      ensure
        w.finish rescue nil
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
