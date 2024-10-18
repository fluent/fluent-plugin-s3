require 'fluent/plugin/output'
require 'fluent/log-ext'
require 'fluent/timezone'
require 'aws-sdk-s3'
require 'zlib'
require 'time'
require 'tempfile'
require 'securerandom'
require 'zstd-ruby'

module Fluent::Plugin
  class S3Output < Output
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
    desc "Use aws-sdk-ruby bundled cert"
    config_param :use_bundled_cert, :bool, default: false
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
      desc "The region of the STS endpoint to use."
      config_param :sts_region, :string, default: nil
      desc "A http proxy url for requests to aws sts service"
      config_param :sts_http_proxy, :string, default: nil, secret: true
      desc "A url for a regional sts api endpoint, the default is global"
      config_param :sts_endpoint_url, :string, default: nil
    end
    # See the following link for additional params that could be added:
    # https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/STS/Client.html#assume_role_with_web_identity-instance_method
    config_section :web_identity_credentials, multi: false do
      desc "The Amazon Resource Name (ARN) of the role to assume"
      config_param :role_arn, :string # required
      desc "An identifier for the assumed role session"
      config_param :role_session_name, :string #required
      desc "The absolute path to the file on disk containing the OIDC token"
      config_param :web_identity_token_file, :string #required
      desc "An IAM policy in JSON format"
      config_param :policy, :string, default: nil
      desc "The duration, in seconds, of the role session (900-43200)"
      config_param :duration_seconds, :integer, default: nil
      desc "The region of the STS endpoint to use."
      config_param :sts_region, :string, default: nil
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
    config_param :aws_iam_retries, :integer, default: nil, deprecated: "Use 'instance_profile_credentials' instead"
    desc "S3 bucket name"
    config_param :s3_bucket, :string
    desc "S3 region name"
    config_param :s3_region, :string, default: ENV["AWS_REGION"] || "us-east-1"
    desc "Use 's3_region' instead"
    config_param :s3_endpoint, :string, default: nil
    desc "If true, S3 Transfer Acceleration will be enabled for uploads. IMPORTANT: You must first enable this feature on your destination S3 bucket"
    config_param :enable_transfer_acceleration, :bool, default: false
    desc "If true, use Amazon S3 Dual-Stack Endpoints. Will make it possible to use either IPv4 or IPv6 when connecting to S3."
    config_param :enable_dual_stack, :bool, default: false
    desc "If false, the certificate of endpoint will not be verified"
    config_param :ssl_verify_peer, :bool, :default => true
    desc "Full path to the SSL certificate authority bundle file that should be used when verifying peer certificates. If unspecified, defaults to the system CA if available."
    config_param :ssl_ca_bundle, :string, :default => nil
    desc "Full path of the directory that contains the unbundled SSL certificate authority files for verifying peer certificates. If you do not pass ssl_ca_bundle or ssl_ca_directory the the system default will be used if available."
    config_param :ssl_ca_directory, :string, :default => nil
    desc "The format of S3 object keys"
    config_param :s3_object_key_format, :string, default: "%{path}%{time_slice}_%{index}.%{file_extension}"
    desc "If true, the bucket name is always left in the request URI and never moved to the host as a sub-domain"
    config_param :force_path_style, :bool, default: false, deprecated: "S3 will drop path style API in 2020: See https://aws.amazon.com/blogs/aws/amazon-s3-path-deprecation-plan-the-rest-of-the-story/"
    desc "Archive format on S3"
    config_param :store_as, :string, default: "gzip"
    desc "Create S3 bucket if it does not exists"
    config_param :auto_create_bucket, :bool, default: true
    desc "Check AWS key on start"
    config_param :check_apikey_on_start, :bool, default: true
    desc "URI of proxy environment"
    config_param :proxy_uri, :string, default: nil
    desc "Use S3 reduced redundancy storage for 33% cheaper pricing. Deprecated. Use storage_class instead"
    config_param :reduced_redundancy, :bool, default: false, deprecated: "Use storage_class parameter instead."
    desc "The type of storage to use for the object(STANDARD,REDUCED_REDUNDANCY,STANDARD_IA)"
    config_param :storage_class, :string, default: "STANDARD"
    desc "Permission for the object in S3"
    config_param :acl, :string, default: nil
    desc "Allows grantee READ, READ_ACP, and WRITE_ACP permissions on the object"
    config_param :grant_full_control, :string, default: nil
    desc "Allows grantee to read the object data and its metadata"
    config_param :grant_read, :string, default: nil
    desc "Allows grantee to read the object ACL"
    config_param :grant_read_acp, :string, default: nil
    desc "Allows grantee to write the ACL for the applicable object"
    config_param :grant_write_acp, :string, default: nil
    desc "The length of `%{hex_random}` placeholder(4-16)"
    config_param :hex_random_length, :integer, default: 4
    desc "`sprintf` format for `%{index}`"
    config_param :index_format, :string, default: "%d"
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
    desc "Arbitrary S3 tag-set for the object"
    config_param :tagging, :string, default: nil
    desc "Arbitrary S3 metadata headers to set for the object"
    config_param :s3_metadata, :hash, default: nil
    config_section :bucket_lifecycle_rule, param_name: :bucket_lifecycle_rules, multi: true do
      desc "A unique ID for this rule"
      config_param :id, :string
      desc "Objects whose keys begin with this prefix will be affected by the rule. If not specified all objects of the bucket will be affected"
      config_param :prefix, :string, default: ''
      desc "The number of days before the object will expire"
      config_param :expiration_days, :integer
    end

    DEFAULT_FORMAT_TYPE = "out_file"

    config_section :format do
      config_set_default :@type, DEFAULT_FORMAT_TYPE
    end

    config_section :buffer do
      config_set_default :chunk_keys, ['time']
      config_set_default :timekey, (60 * 60 * 24)
    end

    attr_reader :bucket

    MAX_HEX_RANDOM_LENGTH = 16

    def reject_s3_endpoint?
      @s3_endpoint && !@s3_endpoint.end_with?('vpce.amazonaws.com') &&
        @s3_endpoint.end_with?('amazonaws.com') && !['fips', 'gov'].any? { |e| @s3_endpoint.include?(e) }
    end

    def configure(conf)
      compat_parameters_convert(conf, :buffer, :formatter, :inject)

      super

      Aws.use_bundled_cert! if @use_bundled_cert

      if reject_s3_endpoint?
        raise Fluent::ConfigError, "s3_endpoint parameter is not supported for S3, use s3_region instead. This parameter is for S3 compatible services"
      end

      begin
        buffer_type = @buffer_config[:@type]
        @compressor = COMPRESSOR_REGISTRY.lookup(@store_as).new(buffer_type: buffer_type, log: log)
      rescue => e
        log.warn "'#{@store_as}' not supported. Use 'text' instead: error = #{e.message}"
        @compressor = TextCompressor.new
      end
      @compressor.configure(conf)

      @formatter = formatter_create

      if @hex_random_length > MAX_HEX_RANDOM_LENGTH
        raise Fluent::ConfigError, "hex_random_length parameter must be less than or equal to #{MAX_HEX_RANDOM_LENGTH}"
      end

      unless @index_format =~ /^%(0\d*)?[dxX]$/
        raise Fluent::ConfigError, "index_format parameter should follow `%[flags][width]type`. `0` is the only supported flag, and is mandatory if width is specified. `d`, `x` and `X` are supported types"
      end

      if @reduced_redundancy
        log.warn "reduced_redundancy parameter is deprecated. Use storage_class parameter instead"
        @storage_class = "REDUCED_REDUNDANCY"
      end

      @s3_object_key_format = process_s3_object_key_format
      if !@check_object
        if conf.has_key?('s3_object_key_format')
          log.warn "Set 'check_object false' and s3_object_key_format is specified. Check s3_object_key_format is unique in each write. If not, existing file will be overwritten."
        else
          log.warn "Set 'check_object false' and s3_object_key_format is not specified. Use '%{path}/%{time_slice}_%{hms_slice}.%{file_extension}' for s3_object_key_format"
          @s3_object_key_format = "%{path}/%{time_slice}_%{hms_slice}.%{file_extension}"
        end
      end

      check_s3_path_safety(conf)

      # For backward compatibility
      # TODO: Remove time_slice_format when end of support compat_parameters
      @configured_time_slice_format = conf['time_slice_format']
      @values_for_s3_object_chunk = {}
      @time_slice_with_tz = Fluent::Timezone.formatter(@timekey_zone, @configured_time_slice_format || timekey_to_timeformat(@buffer_config['timekey']))
    end

    def multi_workers_ready?
      true
    end

    def start
      options = setup_credentials
      options[:region] = @s3_region if @s3_region
      options[:endpoint] = @s3_endpoint if @s3_endpoint
      options[:use_accelerate_endpoint] = @enable_transfer_acceleration
      options[:use_dualstack_endpoint] = @enable_dual_stack
      options[:http_proxy] = @proxy_uri if @proxy_uri
      options[:force_path_style] = @force_path_style
      options[:compute_checksums] = @compute_checksums unless @compute_checksums.nil?
      options[:signature_version] = @signature_version unless @signature_version.nil?
      options[:ssl_verify_peer] = @ssl_verify_peer
      options[:ssl_ca_bundle] = @ssl_ca_bundle if @ssl_ca_bundle
      options[:ssl_ca_directory] = @ssl_ca_directory if @ssl_ca_directory
      log.on_trace do
        options[:http_wire_trace] = true
        options[:logger] = log
      end

      s3_client = Aws::S3::Client.new(options)
      @s3 = Aws::S3::Resource.new(client: s3_client)
      @bucket = @s3.bucket(@s3_bucket)

      check_apikeys if @check_apikey_on_start
      ensure_bucket if @check_bucket
      ensure_bucket_lifecycle

      super
    end

    def format(tag, time, record)
      r = inject_values_to_record(tag, time, record)
      @formatter.format(tag, time, r)
    end

    def write(chunk)
      i = 0
      metadata = chunk.metadata
      previous_path = nil
      time_slice = if metadata.timekey.nil?
                     ''.freeze
                   else
                     @time_slice_with_tz.call(metadata.timekey)
                   end

      if @check_object
        begin
          @values_for_s3_object_chunk[chunk.unique_id] ||= {
            "%{hex_random}" => hex_random(chunk),
          }
          values_for_s3_object_key_pre = {
            "%{path}" => @path,
            "%{file_extension}" => @compressor.ext,
          }
          values_for_s3_object_key_post = {
            "%{time_slice}" => time_slice,
            "%{index}" => sprintf(@index_format,i),
          }.merge!(@values_for_s3_object_chunk[chunk.unique_id])
          values_for_s3_object_key_post["%{uuid_flush}".freeze] = uuid_random if @uuid_flush_enabled

          s3path = @s3_object_key_format.gsub(%r(%{[^}]+})) do |matched_key|
            values_for_s3_object_key_pre.fetch(matched_key, matched_key)
          end
          s3path = extract_placeholders(s3path, chunk)
          s3path = s3path.gsub(%r(%{[^}]+}), values_for_s3_object_key_post)
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

        @values_for_s3_object_chunk[chunk.unique_id] ||= {
          "%{hex_random}" => hex_random(chunk),
        }
        values_for_s3_object_key_pre = {
          "%{path}" => @path,
          "%{file_extension}" => @compressor.ext,
        }
        values_for_s3_object_key_post = {
          "%{date_slice}" => time_slice,  # For backward compatibility
          "%{time_slice}" => time_slice,
          "%{hms_slice}" => hms_slicer,
        }.merge!(@values_for_s3_object_chunk[chunk.unique_id])
        values_for_s3_object_key_post["%{uuid_flush}".freeze] = uuid_random if @uuid_flush_enabled

        s3path = @s3_object_key_format.gsub(%r(%{[^}]+})) do |matched_key|
          values_for_s3_object_key_pre.fetch(matched_key, matched_key)
        end
        s3path = extract_placeholders(s3path, chunk)
        s3path = s3path.gsub(%r(%{[^}]+}), values_for_s3_object_key_post)
      end

      tmp = Tempfile.new("s3-")
      tmp.binmode
      begin
        @compressor.compress(chunk, tmp)
        tmp.rewind
        log.debug "out_s3: write chunk #{dump_unique_id_hex(chunk.unique_id)} with metadata #{chunk.metadata} to s3://#{@s3_bucket}/#{s3path}"

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
        put_options[:grant_full_control] = @grant_full_control if @grant_full_control
        put_options[:grant_read] = @grant_read if @grant_read
        put_options[:grant_read_acp] = @grant_read_acp if @grant_read_acp
        put_options[:grant_write_acp] = @grant_write_acp if @grant_write_acp
        put_options[:tagging] = @tagging if @tagging

        if @s3_metadata
          put_options[:metadata] = {}
          @s3_metadata.each do |k, v|
            put_options[:metadata][k] = extract_placeholders(v, chunk).gsub(%r(%{[^}]+}), {"%{index}" => sprintf(@index_format, i - 1)})
          end
        end
        @bucket.object(s3path).put(put_options)

        @values_for_s3_object_chunk.delete(chunk.unique_id)

        if @warn_for_delay
          if Time.at(chunk.metadata.timekey) < Time.now - @warn_for_delay
            log.warn "out_s3: delayed events were put to s3://#{@s3_bucket}/#{s3path}"
          end
        end
      ensure
        tmp.close(true) rescue nil
      end
    end

    private

    def hex_random(chunk)
      unique_hex = Fluent::UniqueId.hex(chunk.unique_id)
      unique_hex.reverse! # unique_hex is like (time_sec, time_usec, rand) => reversing gives more randomness
      unique_hex[0...@hex_random_length]
    end

    def uuid_random
      SecureRandom.uuid
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

    def ensure_bucket_lifecycle
      unless @bucket_lifecycle_rules.empty?
        old_rules = get_bucket_lifecycle_rules
        new_rules = @bucket_lifecycle_rules.sort_by { |rule| rule.id }.map do |rule|
          { id: rule.id, expiration: { days: rule.expiration_days }, prefix: rule.prefix, status: "Enabled" }
        end

        unless old_rules == new_rules
          log.info "Configuring bucket lifecycle rules for #{@s3_bucket} on #{@s3_endpoint}"
          @bucket.lifecycle_configuration.put({ lifecycle_configuration: { rules: new_rules } })
        end
      end
    end

    def get_bucket_lifecycle_rules
      begin
        @bucket.lifecycle_configuration.rules.sort_by { |rule| rule[:id] }.map do |rule|
          { id: rule[:id], expiration: { days: rule[:expiration][:days] }, prefix: rule[:prefix], status: rule[:status] }
        end
      rescue Aws::S3::Errors::NoSuchLifecycleConfiguration
        []
      end
    end

    def process_s3_object_key_format
      %W(%{uuid} %{uuid:random} %{uuid:hostname} %{uuid:timestamp}).each { |ph|
        if @s3_object_key_format.include?(ph)
          raise Fluent::ConfigError, %!#{ph} placeholder in s3_object_key_format is removed!
        end
      }

      if @s3_object_key_format.include?('%{uuid_flush}')
        @uuid_flush_enabled = true
      end

      @s3_object_key_format.gsub('%{hostname}') { |expr|
        log.warn "%{hostname} will be removed in the future. Use \"\#{Socket.gethostname}\" instead"
        Socket.gethostname
      }
    end

    def check_s3_path_safety(conf)
      unless conf.has_key?('s3_object_key_format')
        log.warn "The default value of s3_object_key_format will use ${chunk_id} instead of %{index} to avoid object conflict in v2"
      end

      is_working_on_parallel = @buffer_config.flush_thread_count > 1 || system_config.workers > 1
      if is_working_on_parallel && ['${chunk_id}', '%{uuid_flush}', '%{hex_random}'].none? { |key| @s3_object_key_format.include?(key) }
        log.warn "No ${chunk_id}, %{uuid_flush} or %{hex_random} in s3_object_key_format with multiple flush threads or multiple workers. Recommend to set ${chunk_id}, %{uuid_flush} or %{hex_random} to avoid data lost by object conflict"
      end
    end

    def check_apikeys
      @bucket.objects(prefix: @path, :max_keys => 1).first
    rescue Aws::S3::Errors::NoSuchBucket
      # ignore NoSuchBucket Error because ensure_bucket checks it.
    rescue => e
      raise "can't call S3 API. Please check your credentials or s3_region configuration. error = #{e.inspect}"
    end

    def setup_credentials
      options = {}
      credentials_options = {}
      case
      when @assume_role_credentials
        c = @assume_role_credentials
        iam_user_credentials = @aws_key_id && @aws_sec_key ? Aws::Credentials.new(@aws_key_id, @aws_sec_key) : nil
        region = c.sts_region || @s3_region
        credentials_options[:role_arn] = c.role_arn
        credentials_options[:role_session_name] = c.role_session_name
        credentials_options[:policy] = c.policy if c.policy
        credentials_options[:duration_seconds] = c.duration_seconds if c.duration_seconds
        credentials_options[:external_id] = c.external_id if c.external_id
        credentials_options[:sts_endpoint_url] = c.sts_endpoint_url if c.sts_endpoint_url
        credentials_options[:sts_http_proxy] = c.sts_http_proxy if c.sts_http_proxy
        if c.sts_http_proxy && c.sts_endpoint_url
          credentials_options[:client] = if iam_user_credentials
                                           Aws::STS::Client.new(region: region, http_proxy: c.sts_http_proxy, endpoint: c.sts_endpoint_url, credentials: iam_user_credentials)
                                         else
                                           Aws::STS::Client.new(region: region, http_proxy: c.sts_http_proxy, endpoint: c.sts_endpoint_url)
                                         end
        elsif c.sts_http_proxy
          credentials_options[:client] = if iam_user_credentials
                                           Aws::STS::Client.new(region: region, http_proxy: c.sts_http_proxy, credentials: iam_user_credentials)
                                         else
                                           Aws::STS::Client.new(region: region, http_proxy: c.sts_http_proxy)
                                         end
        elsif c.sts_endpoint_url
          credentials_options[:client] = if iam_user_credentials
                                           Aws::STS::Client.new(region: region, endpoint: c.sts_endpoint_url, credentials: iam_user_credentials)
                                         else
                                           Aws::STS::Client.new(region: region, endpoint: c.sts_endpoint_url)
                                         end
        else
          credentials_options[:client] = if iam_user_credentials
                                           Aws::STS::Client.new(region: region, credentials: iam_user_credentials)
                                         else
                                           Aws::STS::Client.new(region: region)
                                         end
        end

        options[:credentials] = Aws::AssumeRoleCredentials.new(credentials_options)
      when @aws_key_id && @aws_sec_key
        options[:access_key_id] = @aws_key_id
        options[:secret_access_key] = @aws_sec_key
      when @web_identity_credentials
        c = @web_identity_credentials
        credentials_options[:role_arn] = c.role_arn
        credentials_options[:role_session_name] = c.role_session_name
        credentials_options[:web_identity_token_file] = c.web_identity_token_file
        credentials_options[:policy] = c.policy if c.policy
        credentials_options[:duration_seconds] = c.duration_seconds if c.duration_seconds
        if c.sts_region
          credentials_options[:client] = Aws::STS::Client.new(:region => c.sts_region)
        elsif @s3_region
          credentials_options[:client] = Aws::STS::Client.new(:region => @s3_region)
        end
        options[:credentials] = Aws::AssumeRoleWebIdentityCredentials.new(credentials_options)
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

    class ZstdCompressor < Compressor
      def ext
        'zst'.freeze
      end

      def content_type
        'application/x-zst'.freeze
      end

      def compress(chunk, tmp)
        uncompressed_data = ''
        chunk.open do |io|
          uncompressed_data = io.read
        end
        compressed_data = Zstd.compress(uncompressed_data, level: @level)
        tmp.write(compressed_data)
      rescue => e
        log.warn "zstd compression failed: #{e.message}"
        raise e
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
      'text' => TextCompressor,
      'zstd' => ZstdCompressor
    }.each { |name, compressor|
      COMPRESSOR_REGISTRY.register(name, compressor)
    }

    def self.register_compressor(name, compressor)
      COMPRESSOR_REGISTRY.register(name, compressor)
    end
  end
end
