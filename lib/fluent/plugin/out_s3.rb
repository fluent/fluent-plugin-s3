require 'fluent/output'
require 'aws-sdk-resources'
require 'zlib'
require 'time'
require 'tempfile'

module Fluent::Plugin
  class S3Output < Fluent::Plugin::Output
    Fluent::Plugin.register_output('s3', self)

    helpers :compat_parameters, :formatter, :inject

    def initialize
      super
      @compressor = nil
      @uuid_flush_enabled = false
    end

    desc "Path prefix of the files on S3"
    config_param :path, :string, default: ""
    desc "The Server-side encryption algorithm used when storing this object in S3 (AES256, aws:kms)"
    config_param :use_server_side_encryption, :string, default: nil
    desc "AWS access key id"
    config_param :aws_key_id, :string, default: nil, secret: true
    desc "AWS secret key."
    config_param :aws_sec_key, :string, default: nil, secret: true
    config_section :assume_role_credentials, multi: false do
      desc "The Amazon Resource Name (ARN) of the role to assume"
      config_param :role_arn, :string, secret: true
      desc "An identifier for the assumed role session"
      config_param :role_session_name, :string
      desc "An IAM policy in JSON format"
      config_param :policy, :string, default: nil
      desc "The duration, in seconds, of the role session (900-3600)"
      config_param :duration_seconds, :integer, default: nil
      desc "A unique identifier that is used by third parties when assuming roles in their customers' accounts."
      config_param :external_id, :string, default: nil, secret: true
    end
    config_section :instance_profile_credentials, multi: false do
      desc "Number of times to retry when retrieving credentials"
      config_param :retries, :integer, default: nil
      desc "IP address (default:169.254.169.254)"
      config_param :ip_address, :string, default: nil
      desc "Port number (default:80)"
      config_param :port, :integer, default: nil
      desc "Number of seconds to wait for the connection to open"
      config_param :http_open_timeout, :float, default: nil
      desc "Number of seconds to wait for one block to be read"
      config_param :http_read_timeout, :float, default: nil
      # config_param :delay, :integer or :proc, :default => nil
      # config_param :http_degub_output, :io, :default => nil
    end
    config_section :shared_credentials, multi: false do
      desc "Path to the shared file. (default: $HOME/.aws/credentials)"
      config_param :path, :string, default: nil
      desc "Profile name. Default to 'default' or ENV['AWS_PROFILE']"
      config_param :profile_name, :string, default: nil
    end
    desc "The number of attempts to load instance profile credentials from the EC2 metadata service using IAM role"
    config_param :aws_iam_retries, :integer, default: nil
    desc "S3 bucket name"
    config_param :s3_bucket, :string
    desc "S3 region name"
    config_param :s3_region, :string, default: ENV["AWS_REGION"] || "us-east-1"
    desc "Use 's3_region' instead"
    config_param :s3_endpoint, :string, default: nil
    desc "The format of S3 object keys"
    config_param :s3_object_key_format, :string, default: "%{path}%{time_slice}_%{index}.%{file_extension}"
    desc "If true, the bucket name is always left in the request URI and never moved to the host as a sub-domain"
    config_param :force_path_style, :bool, default: false
    desc "Archive format on S3"
    config_param :store_as, :string, default: "gzip"
    desc "Create S3 bucket if it does not exists"
    config_param :auto_create_bucket, :bool, default: true
    desc "Check AWS key on start"
    config_param :check_apikey_on_start, :bool, default: true
    desc "URI of proxy environment"
    config_param :proxy_uri, :string, default: nil
    desc "Use S3 reduced redundancy storage for 33% cheaper pricing. Deprecated. Use storage_class instead"
    config_param :reduced_redundancy, :bool, default: false
    desc "The type of storage to use for the object(STANDARD,REDUCED_REDUNDANCY,STANDARD_IA)"
    config_param :storage_class, :string, default: "STANDARD"
    desc "Permission for the object in S3"
    config_param :acl, :string, default: nil
    desc "The length of `%{hex_random}` placeholder(4-16)"
    config_param :hex_random_length, :integer, default: 4
    desc "Overwrite already existing path"
    config_param :overwrite, :bool, default: false
    desc "Check bucket if exists or not"
    config_param :check_bucket, :bool, default: true
    desc "Check object before creation"
    config_param :check_object, :bool, default: true
    desc "Specifies the AWS KMS key ID to use for object encryption"
    config_param :ssekms_key_id, :string, default: nil, secret: true
    desc "Specifies the algorithm to use to when encrypting the object"
    config_param :sse_customer_algorithm, :string, default: nil
    desc "Specifies the customer-provided encryption key for Amazon S3 to use in encrypting data"
    config_param :sse_customer_key, :string, default: nil, secret: true
    desc "Specifies the 128-bit MD5 digest of the encryption key according to RFC 1321"
    config_param :sse_customer_key_md5, :string, default: nil, secret: true
    desc "AWS SDK uses MD5 for API request/response by default"
    config_param :compute_checksums, :bool, default: nil # use nil to follow SDK default configuration
    desc "Signature version for API Request (s3,v4)"
    config_param :signature_version, :string, default: nil # use nil to follow SDK default configuration
    desc "Given a threshold to treat events as delay, output warning logs if delayed events were put into s3"
    config_param :warn_for_delay, :time, default: nil

    DEFAULT_FORMAT_TYPE = "out_file"

    config_section :format do
      config_set_default :@type, DEFAULT_FORMAT_TYPE
    end

    attr_reader :bucket

    MAX_HEX_RANDOM_LENGTH = 16

    def configure(conf)
      compat_parameters_convert(conf, :buffer, :formatter, :inject)

      super

      if @s3_endpoint && @s3_endpoint.end_with?('amazonaws.com')
        raise Fluent::ConfigError, "s3_endpoint parameter is not supported for S3, use s3_region instead. This parameter is for S3 compatible services"
      end

      begin
        buffer_type = @buffer_config[:@type]
        @compressor = COMPRESSOR_REGISTRY.lookup(@store_as).new(buffer_type: buffer_type, log: log)
      rescue
        log.warn "#{@store_as} not found. Use 'text' instead"
        @compressor = TextCompressor.new
      end
      @compressor.configure(conf)

      @formatter = formatter_create(conf: conf.elements("format").first, default_type: DEFAULT_FORMAT_TYPE)

      if @hex_random_length > MAX_HEX_RANDOM_LENGTH
        raise Fluent::ConfigError, "hex_random_length parameter must be less than or equal to #{MAX_HEX_RANDOM_LENGTH}"
      end

      if @reduced_redundancy
        log.warn "reduced_redundancy parameter is deprecated. Use storage_class parameter instead"
        @storage_class = "REDUCED_REDUNDANCY"
      end

      @s3_object_key_format = process_s3_object_key_format
      # For backward compatibility
      # TODO: Remove time_slice_format when end of support compat_parameters
      @configured_time_slice_format = conf['time_slice_format']
      @values_for_s3_object_chunk = {}
    end

    def start
      options = setup_credentials
      options[:region] = @s3_region if @s3_region
      options[:endpoint] = @s3_endpoint if @s3_endpoint
      options[:http_proxy] = @proxy_uri if @proxy_uri
      options[:force_path_style] = @force_path_style
      options[:compute_checksums] = @compute_checksums unless @compute_checksums.nil?
      options[:signature_version] = @signature_version unless @signature_version.nil?

      s3_client = Aws::S3::Client.new(options)
      @s3 = Aws::S3::Resource.new(client: s3_client)
      @bucket = @s3.bucket(@s3_bucket)

      check_apikeys if @check_apikey_on_start
      ensure_bucket if @check_bucket

      if !@check_object
        @s3_object_key_format = "%{path}/%{date_slice}_%{hms_slice}.%{file_extension}"
      end

      super
    end

    def format(tag, time, record)
      r = inject_values_to_record(tag, time, record)
      @formatter.format(tag, time, r)
    end

    def write(chunk)
      i = 0
      previous_path = nil
      time_slice_format = @configured_time_slice_format || timekey_to_timeformat(@buffer_config['timekey'])
      time_slice = Time.at(chunk.metadata.timekey).utc.strftime(time_slice_format)

      if @check_object
        begin
          path = extract_placeholders(@path, chunk.metadata)

          @values_for_s3_object_chunk[chunk.unique_id] ||= {
            "%{hex_random}" => hex_random(chunk),
          }
          values_for_s3_object_key = {
            "%{path}" => path,
            "%{time_slice}" => chunk.key,
            "%{file_extension}" => @compressor.ext,
            "%{index}" => i,
          }.merge!(@values_for_s3_object_chunk[chunk.unique_id])
          values_for_s3_object_key["%{uuid_flush}".freeze] = uuid_random if @uuid_flush_enabled

          s3path = @s3_object_key_format.gsub(%r(%{[^}]+}), values_for_s3_object_key)
          if (i > 0) && (s3path == previous_path)
            if @overwrite
              log.warn "#{s3path} already exists, but will overwrite"
              break
            else
              raise "duplicated path is generated. use %{index} in s3_object_key_format: path = #{s3path}"
            end
          end

          i += 1
          previous_path = s3path
        end while @bucket.object(s3path).exists?
      else
        if @localtime
          hms_slicer = Time.now.strftime("%H%M%S")
        else
          hms_slicer = Time.now.utc.strftime("%H%M%S")
        end

        path = extract_placeholders(@path, chunk.metadata)

        @values_for_s3_object_chunk[chunk.unique_id] ||= {
          "%{hex_random}" => hex_random(chunk),
        }
        values_for_s3_object_key = {
          "%{path}" => path,
          "%{time_slice}" => time_slice,
          "%{file_extension}" => @compressor.ext,
        }.merge!(@values_for_s3_object_chunk[chunk.unique_id])
        values_for_s3_object_key["%{uuid_flush}".freeze] = uuid_random if @uuid_flush_enabled

        s3path = @s3_object_key_format.gsub(%r(%{[^}]+}), values_for_s3_object_key)
      end

      tmp = Tempfile.new("s3-")
      tmp.binmode
      begin
        @compressor.compress(chunk, tmp)
        tmp.rewind
        log.debug { "out_s3: write chunk: {key:#{chunk.key},tsuffix:#{tsuffix(chunk)}} to s3://#{@s3_bucket}/#{s3path}" }

        put_options = {
          body: tmp,
          content_type: @compressor.content_type,
          storage_class: @storage_class,
        }
        put_options[:server_side_encryption] = @use_server_side_encryption if @use_server_side_encryption
        put_options[:ssekms_key_id] = @ssekms_key_id if @ssekms_key_id
        put_options[:sse_customer_algorithm] = @sse_customer_algorithm if @sse_customer_algorithm
        put_options[:sse_customer_key] = @sse_customer_key if @sse_customer_key
        put_options[:sse_customer_key_md5] = @sse_customer_key_md5 if @sse_customer_key_md5
        put_options[:acl] = @acl if @acl
        @bucket.object(s3path).put(put_options)

        @values_for_s3_object_chunk.delete(chunk.unique_id)

        if @warn_for_delay
          if Time.strptime(chunk.key, time_slice_format) < Time.now - @warn_for_delay
            log.warn { "out_s3: delayed events were put to s3://#{@s3_bucket}/#{s3path}" }
          end
        end
      ensure
        tmp.close(true) rescue nil
      end
    end

    private

    # v0.14 has a useful Fluent::UniqueId.hex(unique_id) method, though
    def unique_hex(chunk)
      unique_id = chunk.unique_id
      unique_id.unpack('C*').map {|x| x.to_s(16) }.join('')
    end

    def hex_random(chunk)
      unique_hex = unique_hex(chunk)
      unique_hex.reverse! # unique_hex is like (time_sec, time_usec, rand) => reversing gives more randomness
      unique_hex[0...@hex_random_length]
    end

    def uuid_random
      ::UUIDTools::UUID.random_create.to_s
    end

    # This is stolen from Fluentd
    def timekey_to_timeformat(timekey)
      case timekey
      when nil          then ''
      when 0...60       then '%Y%m%d%H%M%S' # 60 exclusive
      when 60...3600    then '%Y%m%d%H%M'
      when 3600...86400 then '%Y%m%d%H'
      else                   '%Y%m%d'
      end
    end

    def ensure_bucket
      if !@bucket.exists?
        if @auto_create_bucket
          log.info "Creating bucket #{@s3_bucket} on #{@s3_endpoint}"
          @s3.create_bucket(bucket: @s3_bucket)
        else
          raise "The specified bucket does not exist: bucket = #{@s3_bucket}"
        end
      end
    end

    def process_s3_object_key_format
      %W(%{uuid} %{uuid:random} %{uuid:hostname} %{uuid:timestamp}).each { |ph|
        if @s3_object_key_format.include?(ph)
          raise ConfigError, %!#{ph} placeholder in s3_object_key_format is removed!
        end
      }

      if @s3_object_key_format.include?('%{uuid_flush}')
        # test uuidtools works or not
        begin
          require 'uuidtools'
        rescue LoadError
          raise ConfigError, "uuidtools gem not found. Install uuidtools gem first"
        end
        begin
          uuid_random
        rescue => e
          raise ConfigError, "Generating uuid doesn't work. Can't use %{uuid_flush} on this environment. #{e}"
        end
        @uuid_flush_enabled = true
      end

      @s3_object_key_format.gsub('%{hostname}') { |expr|
        log.warn "%{hostname} will be removed in the future. Use \"\#{Socket.gethostname}\" instead"
        Socket.gethostname
      }
    end

    def check_apikeys
      @bucket.objects(prefix: @path).first
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
        if @s3_region
          credentials_options[:client] = Aws::STS::Client.new(region: @s3_region)
        end
        options[:credentials] = Aws::AssumeRoleCredentials.new(credentials_options)
      when @instance_profile_credentials
        c = @instance_profile_credentials
        credentials_options[:retries] = c.retries if c.retries
        credentials_options[:ip_address] = c.ip_address if c.ip_address
        credentials_options[:port] = c.port if c.port
        credentials_options[:http_open_timeout] = c.http_open_timeout if c.http_open_timeout
        credentials_options[:http_read_timeout] = c.http_read_timeout if c.http_read_timeout
        if ENV["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
          options[:credentials] = Aws::ECSCredentials.new(credentials_options)
        else
          options[:credentials] = Aws::InstanceProfileCredentials.new(credentials_options)
        end
      when @shared_credentials
        c = @shared_credentials
        credentials_options[:path] = c.path if c.path
        credentials_options[:profile_name] = c.profile_name if c.profile_name
        options[:credentials] = Aws::SharedCredentials.new(credentials_options)
      when @aws_iam_retries
        log.warn("'aws_iam_retries' parameter is deprecated. Use 'instance_profile_credentials' instead")
        credentials_options[:retries] = @aws_iam_retries
        if ENV["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
          options[:credentials] = Aws::ECSCredentials.new(credentials_options)
        else
          options[:credentials] = Aws::InstanceProfileCredentials.new(credentials_options)
        end
      else
        # Use default credentials
        # See http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Client.html
      end
      options
    end

    class Compressor
      include Fluent::Configurable

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
          raise Fluent::ConfigError, "'#{command}' utility must be in PATH for #{algo} compression"
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

    COMPRESSOR_REGISTRY = Fluent::Registry.new(:s3_compressor_type, 'fluent/plugin/s3_compressor_')
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
