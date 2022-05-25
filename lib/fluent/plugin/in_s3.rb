require 'fluent/plugin/input'
require 'fluent/log-ext'

require 'aws-sdk-s3'
require 'aws-sdk-sqs'
require 'aws-sdk-sqs/queue_poller'
require 'cgi/util'
require 'zlib'
require 'time'
require 'tempfile'

module Fluent::Plugin
  class S3Input < Input
    Fluent::Plugin.register_input('s3', self)

    helpers :compat_parameters, :parser, :thread

    def initialize
      super
      @extractor = nil
    end

    DEFAULT_PARSE_TYPE = "none"

    desc "Use aws-sdk-ruby bundled cert"
    config_param :use_bundled_cert, :bool, default: false
    desc "Add object metadata to the records parsed out of a given object"
    config_param :add_object_metadata, :bool, default: false
    desc "AWS access key id"
    config_param :aws_key_id, :string, default: nil, secret: true
    desc "AWS secret key."
    config_param :aws_sec_key, :string, default: nil, secret: true
    config_section :assume_role_credentials, multi: false do
      desc "The Amazon Resource Name (ARN) of the role to assume"
      config_param :role_arn, :string
      desc "An identifier for the assumed role session"
      config_param :role_session_name, :string
      desc "An IAM policy in JSON format"
      config_param :policy, :string, default: nil
      desc "The duration, in seconds, of the role session (900-3600)"
      config_param :duration_seconds, :integer, default: nil
      desc "A unique identifier that is used by third parties when assuming roles in their customers' accounts."
      config_param :external_id, :string, default: nil
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
    desc "S3 bucket name"
    config_param :s3_bucket, :string
    desc "S3 region name"
    config_param :s3_region, :string, default: ENV["AWS_REGION"] || "us-east-1"
    desc "Use 's3_region' instead"
    config_param :s3_endpoint, :string, default: nil
    desc "If true, the bucket name is always left in the request URI and never moved to the host as a sub-domain"
    config_param :force_path_style, :bool, default: false
    desc "Archive format on S3"
    config_param :store_as, :string, default: "gzip"
    desc "Check AWS key on start"
    config_param :check_apikey_on_start, :bool, default: true
    desc "URI of proxy environment"
    config_param :proxy_uri, :string, default: nil
    desc "Optional RegEx to match incoming messages"
    config_param :match_regexp, :regexp, default: nil

    config_section :sqs, required: true, multi: false do
      desc "SQS queue name"
      config_param :queue_name, :string, default: nil
      desc "SQS Owner Account ID"
      config_param :queue_owner_aws_account_id, :string, default: nil
      desc "Use 's3_region' instead"
      config_param :endpoint, :string, default: nil
      desc "AWS access key id for SQS user"
      config_param :aws_key_id, :string, default: nil, secret: true
      desc "AWS secret key for SQS user."
      config_param :aws_sec_key, :string, default: nil, secret: true
      desc "Skip message deletion"
      config_param :skip_delete, :bool, default: false
      desc "The long polling interval."
      config_param :wait_time_seconds, :integer, default: 20
      desc "Polling error retry interval."
      config_param :retry_error_interval, :integer, default: 300
    end

    desc "Tag string"
    config_param :tag, :string, default: "input.s3"

    config_section :parse do
      config_set_default :@type, DEFAULT_PARSE_TYPE
    end

    attr_reader :bucket

    def reject_s3_endpoint?
      @s3_endpoint && !@s3_endpoint.end_with?('vpce.amazonaws.com') &&
        @s3_endpoint.end_with?('amazonaws.com') && !['fips', 'gov'].any? { |e| @s3_endpoint.include?(e) }
    end

    def configure(conf)
      super

      if reject_s3_endpoint?
        raise Fluent::ConfigError, "s3_endpoint parameter is not supported for S3, use s3_region instead. This parameter is for S3 compatible services"
      end

      if @sqs.endpoint && (@sqs.endpoint.end_with?('amazonaws.com') && !['fips', 'gov'].any? { |e| @sqs.endpoint.include?(e) })
        raise Fluent::ConfigError, "sqs/endpoint parameter is not supported for SQS, use s3_region instead. This parameter is for SQS compatible services"
      end

      parser_config = conf.elements("parse").first
      unless @sqs.queue_name
        raise Fluent::ConfigError, "sqs/queue_name is required"
      end

      if !!@aws_key_id ^ !!@aws_sec_key
        raise Fluent::ConfigError, "aws_key_id or aws_sec_key is missing"
      end

      if !!@sqs.aws_key_id ^ !!@sqs.aws_sec_key
        raise Fluent::ConfigError, "sqs/aws_key_id or sqs/aws_sec_key is missing"
      end

      Aws.use_bundled_cert! if @use_bundled_cert

      @extractor = EXTRACTOR_REGISTRY.lookup(@store_as).new(log: log)
      @extractor.configure(conf)

      @parser = parser_create(conf: parser_config, default_type: DEFAULT_PARSE_TYPE)
    end

    def multi_workers_ready?
      true
    end

    def start
      super

      s3_client = create_s3_client
      log.debug("Succeeded to create S3 client")
      @s3 = Aws::S3::Resource.new(client: s3_client)
      @bucket = @s3.bucket(@s3_bucket)

      raise "#{@bucket.name} is not found." unless @bucket.exists?

      check_apikeys if @check_apikey_on_start

      sqs_client = create_sqs_client
      log.debug("Succeeded to create SQS client")
      response = sqs_client.get_queue_url(queue_name: @sqs.queue_name, queue_owner_aws_account_id: @sqs.queue_owner_aws_account_id)
      sqs_queue_url = response.queue_url
      log.debug("Succeeded to get SQS queue URL")

      @poller = Aws::SQS::QueuePoller.new(sqs_queue_url, client: sqs_client)

      @running = true
      thread_create(:in_s3, &method(:run))
    end

    def shutdown
      @running = false
      super
    end

    private

    def run
      options = {}
      options[:wait_time_seconds] = @sqs.wait_time_seconds
      options[:skip_delete] = @sqs.skip_delete
      @poller.before_request do |stats|
        throw :stop_polling unless @running
      end
      begin
        @poller.poll(options) do |message|
          begin
            body = Yajl.load(message.body)
            log.debug(body)
            next unless body["Records"] # skip test queue
            if @match_regexp
              s3 = body["Records"].first["s3"]
              raw_key = s3["object"]["key"]
              key = CGI.unescape(raw_key)
              match_regexp = Regexp.new(@match_regexp)
              next unless match_regexp.match?(key) 
            end
            process(body)
          rescue => e
            log.warn(error: e)
            log.warn_backtrace(e.backtrace)
            throw :skip_delete
          end
        end
      rescue => e
        log.warn("SQS Polling Failed. Retry in #{@sqs.retry_error_interval} seconds", error: e)
        sleep(@sqs.retry_error_interval)
        retry
      end
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
          credentials_options[:client] = Aws::STS::Client.new(:region => @s3_region)
        end
        options[:credentials] = Aws::AssumeRoleCredentials.new(credentials_options)
      when @web_identity_credentials
        c = @web_identity_credentials
        credentials_options[:role_arn] = c.role_arn
        credentials_options[:role_session_name] = c.role_session_name
        credentials_options[:web_identity_token_file] = c.web_identity_token_file
        credentials_options[:policy] = c.policy if c.policy
        credentials_options[:duration_seconds] = c.duration_seconds if c.duration_seconds
        if @s3_region
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
      else
        # Use default credentials
        # See http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Client.html
      end
      options
    end

    def create_s3_client
      options = setup_credentials
      options[:region] = @s3_region if @s3_region
      options[:endpoint] = @s3_endpoint if @s3_endpoint
      options[:force_path_style] = @force_path_style
      options[:http_proxy] = @proxy_uri if @proxy_uri
      log.on_trace do
        options[:http_wire_trace] = true
        options[:logger] = log
      end

      Aws::S3::Client.new(options)
    end

    def create_sqs_client
      options = setup_credentials
      options[:region] = @s3_region if @s3_region
      options[:endpoint] = @sqs.endpoint if @sqs.endpoint
      options[:http_proxy] = @proxy_uri if @proxy_uri
      if @sqs.aws_key_id && @sqs.aws_sec_key
        options[:access_key_id] = @sqs.aws_key_id
        options[:secret_access_key] = @sqs.aws_sec_key
      end
      log.on_trace do
        options[:http_wire_trace] = true
        options[:logger] = log
      end

      Aws::SQS::Client.new(options)
    end

    def check_apikeys
      @bucket.objects.first
      log.debug("Succeeded to verify API keys")
    rescue => e
      raise "can't call S3 API. Please check your credentials or s3_region configuration. error = #{e.inspect}"
    end

    def process(body)
      s3 = body["Records"].first["s3"]
      raw_key = s3["object"]["key"]
      key = CGI.unescape(raw_key)

      io = @bucket.object(key).get.body
      content = @extractor.extract(io)
      es = Fluent::MultiEventStream.new
      content.each_line do |line|
        @parser.parse(line) do |time, record|
          if @add_object_metadata
            record['s3_bucket'] = @s3_bucket
            record['s3_key'] = raw_key
          end
          es.add(time, record)
        end
      end
      router.emit_stream(@tag, es)
    end

    class Extractor
      include Fluent::Configurable

      attr_reader :log

      def initialize(log: $log, **options)
        super()
        @log = log
      end

      def configure(conf)
        super
      end

      def ext
      end

      def content_type
      end

      def extract(io)
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

    class GzipExtractor < Extractor
      def ext
        'gz'.freeze
      end

      def content_type
        'application/x-gzip'.freeze
      end

      # https://bugs.ruby-lang.org/issues/9790
      # https://bugs.ruby-lang.org/issues/11180
      # https://github.com/exAspArk/multiple_files_gzip_reader
      def extract(io)
        parts = []
        loop do
          unused = nil
          Zlib::GzipReader.wrap(io) do |gz|
            parts << gz.read
            unused = gz.unused
            gz.finish
          end
          io.pos -= unused ? unused.length : 0
          break if io.eof?
        end
        io.close
        parts.join
      end
    end

    class TextExtractor < Extractor
      def ext
        'txt'.freeze
      end

      def content_type
        'text/plain'.freeze
      end

      def extract(io)
        io.read
      end
    end

    class JsonExtractor < TextExtractor
      def ext
        'json'.freeze
      end

      def content_type
        'application/json'.freeze
      end
    end

    EXTRACTOR_REGISTRY = Fluent::Registry.new(:s3_extractor_type, 'fluent/plugin/s3_extractor_')
    {
      'gzip' => GzipExtractor,
      'text' => TextExtractor,
      'json' => JsonExtractor
    }.each do |name, extractor|
      EXTRACTOR_REGISTRY.register(name, extractor)
    end

    def self.register_extractor(name, extractor)
      EXTRACTOR_REGISTRY.register(name, extractor)
    end
  end
end
