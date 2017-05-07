require 'fluent/test'
require 'fluent/plugin/out_s3'

require 'test/unit/rr'
require 'zlib'
require 'fileutils'
require 'timecop'

class S3OutputTest < Test::Unit::TestCase
  def setup
    require 'aws-sdk-resources'
    Fluent::Test.setup
  end

  def teardown
    Dir.glob('test/tmp/*').each {|file| FileUtils.rm_f(file) }
  end

  CONFIG = %[
    aws_key_id test_key_id
    aws_sec_key test_sec_key
    s3_bucket test_bucket
    path log
    utc
    buffer_type memory
  ]

  def create_driver(conf = CONFIG)
    Fluent::Test::TimeSlicedOutputTestDriver.new(Fluent::S3Output) do
      def write(chunk)
        chunk.read
      end

      private

      def ensure_bucket
      end

      def check_apikeys
      end
    end.configure(conf)
  end

  def test_configure
    d = create_driver
    assert_equal 'test_key_id', d.instance.aws_key_id
    assert_equal 'test_sec_key', d.instance.aws_sec_key
    assert_equal 'test_bucket', d.instance.s3_bucket
    assert_equal 'log', d.instance.path
    assert_equal 'gz', d.instance.instance_variable_get(:@compressor).ext
    assert_equal 'application/x-gzip', d.instance.instance_variable_get(:@compressor).content_type
    assert_equal false, d.instance.force_path_style
    assert_equal nil, d.instance.compute_checksums
    assert_equal nil, d.instance.signature_version
    assert_equal true, d.instance.check_bucket
    assert_equal true, d.instance.check_object
  end

  def test_s3_endpoint_with_valid_endpoint
    d = create_driver(CONFIG + 's3_endpoint riak-cs.example.com')
    assert_equal 'riak-cs.example.com', d.instance.s3_endpoint
  end

  data('US West (Oregon)' => 's3-us-west-2.amazonaws.com',
       'EU (Frankfurt)' => 's3.eu-central-1.amazonaws.com',
       'Asia Pacific (Tokyo)' => 's3-ap-northeast-1.amazonaws.com')
  def test_s3_endpoint_with_invalid_endpoint(endpoint)
    assert_raise(Fluent::ConfigError, "s3_endpoint parameter is not supported, use s3_region instead. This parameter is for S3 compatible services") {
      d = create_driver(CONFIG + "s3_endpoint #{endpoint}")
    }
  end

  def test_configure_with_mime_type_json
    conf = CONFIG.clone
    conf << "\nstore_as json\n"
    d = create_driver(conf)
    assert_equal 'json', d.instance.instance_variable_get(:@compressor).ext
    assert_equal 'application/json', d.instance.instance_variable_get(:@compressor).content_type
  end

  def test_configure_with_mime_type_text
    conf = CONFIG.clone
    conf << "\nstore_as text\n"
    d = create_driver(conf)
    assert_equal 'txt', d.instance.instance_variable_get(:@compressor).ext
    assert_equal 'text/plain', d.instance.instance_variable_get(:@compressor).content_type
  end

  def test_configure_with_mime_type_lzo
    conf = CONFIG.clone
    conf << "\nstore_as lzo\n"
    d = create_driver(conf)
    assert_equal 'lzo', d.instance.instance_variable_get(:@compressor).ext
    assert_equal 'application/x-lzop', d.instance.instance_variable_get(:@compressor).content_type
  rescue => e
    # TODO: replace code with disable lzop command
    assert(e.is_a?(Fluent::ConfigError))
  end

  def test_configure_with_path_style
    conf = CONFIG.clone
    conf << "\nforce_path_style true\n"
    d = create_driver(conf)
    assert d.instance.force_path_style
  end

  def test_configure_with_compute_checksums
    conf = CONFIG.clone
    conf << "\ncompute_checksums false\n"
    d = create_driver(conf)
    assert_equal false, d.instance.compute_checksums
  end

  def test_configure_with_hex_random_length
    conf = CONFIG.clone
    assert_raise Fluent::ConfigError do
      create_driver(conf + "\nhex_random_length 17\n")
    end
    assert_nothing_raised do
      create_driver(conf + "\nhex_random_length 16\n")
    end
  end

  def test_configure_with_no_check_on_s3
    conf = CONFIG.clone
    conf << "\ncheck_bucket false\ncheck_object false\n"
    d = create_driver(conf)
    assert_equal false, d.instance.check_bucket
    assert_equal false, d.instance.check_object
  end

  def test_config_with_hostname_placeholder
    d = create_driver(<<EOC)
      aws_key_id test_key_id
      aws_sec_key test_sec_key
      s3_bucket test_bucket
      path log/%{hostname}/test
      s3_object_key_format %{path}%{hostname}_%{index}
      buffer_type memory
EOC
    assert_match /#{Socket.gethostname}/, d.instance.s3_object_key_format
    assert_match /#{Socket.gethostname}/, d.instance.path
  end

  def test_path_slicing
    config = CONFIG.clone.gsub(/path\slog/, "path log/%Y/%m/%d")
    d = create_driver(config)
    path_slicer = d.instance.instance_variable_get(:@path_slicer)
    path = d.instance.instance_variable_get(:@path)
    slice = path_slicer.call(path)
    assert_equal slice, Time.now.utc.strftime("log/%Y/%m/%d")
  end

  def test_path_slicing_utc
    config = CONFIG.clone.gsub(/path\slog/, "path log/%Y/%m/%d")
    config << "\nutc\n"
    d = create_driver(config)
    path_slicer = d.instance.instance_variable_get(:@path_slicer)
    path = d.instance.instance_variable_get(:@path)
    slice = path_slicer.call(path)
    assert_equal slice, Time.now.utc.strftime("log/%Y/%m/%d")
  end

  def test_format
    d = create_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n]
    d.expect_format %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n]

    d.run
  end

  def test_format_included_tag_and_time
    config = [CONFIG, 'include_tag_key true', 'include_time_key true'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[2011-01-02T13:14:15Z\ttest\t{"a":1,"tag":"test","time":"2011-01-02T13:14:15Z"}\n]
    d.expect_format %[2011-01-02T13:14:15Z\ttest\t{"a":2,"tag":"test","time":"2011-01-02T13:14:15Z"}\n]

    d.run
  end

  def test_format_with_format_ltsv
    config = [CONFIG, 'format ltsv'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1, "b"=>1}, time)
    d.emit({"a"=>2, "b"=>2}, time)

    d.expect_format %[a:1\tb:1\n]
    d.expect_format %[a:2\tb:2\n]

    d.run
  end

  def test_format_with_format_json
    config = [CONFIG, 'format json'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[{"a":1}\n]
    d.expect_format %[{"a":2}\n]

    d.run
  end

  def test_format_with_format_json_included_tag
    config = [CONFIG, 'format json', 'include_tag_key true'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[{"a":1,"tag":"test"}\n]
    d.expect_format %[{"a":2,"tag":"test"}\n]

    d.run
  end

  def test_format_with_format_json_included_time
    config = [CONFIG, 'format json', 'include_time_key true'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[{"a":1,"time":"2011-01-02T13:14:15Z"}\n]
    d.expect_format %[{"a":2,"time":"2011-01-02T13:14:15Z"}\n]

    d.run
  end

  def test_format_with_format_json_included_tag_and_time
    config = [CONFIG, 'format json', 'include_tag_key true', 'include_time_key true'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[{"a":1,"tag":"test","time":"2011-01-02T13:14:15Z"}\n]
    d.expect_format %[{"a":2,"tag":"test","time":"2011-01-02T13:14:15Z"}\n]

    d.run
  end

  def test_chunk_to_write
    d = create_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # S3OutputTest#write returns chunk.read
    data = d.run

    assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] +
                 %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n],
                 data.first
  end

  CONFIG_TIME_SLICE = %[
    aws_key_id test_key_id
    aws_sec_key test_sec_key
    s3_bucket test_bucket
    s3_object_key_format %{path}/events/ts=%{time_slice}/events_%{index}-%{hostname}.%{file_extension}
    time_slice_format %Y%m%d-%H
    path log
    utc
    buffer_type memory
    log_level debug
    check_bucket true
    check_object true
  ]

  def create_time_sliced_driver(conf = CONFIG_TIME_SLICE)
    d = Fluent::Test::TimeSlicedOutputTestDriver.new(Fluent::S3Output) do
      private

      def check_apikeys
      end
    end.configure(conf)
    d
  end

  def test_write_with_hardened_s3_policy
    # Partial mock the S3Bucket, not to make an actual connection to Amazon S3
    setup_mocks_hardened_policy
    s3_local_file_path = "/tmp/s3-test.txt"
    # @s3_object_key_format will be hard_coded with timestamp only,
    # as in this case, it will not check for object existence, not even bucker existence
    # check_bukcet and check_object both of this config parameter should be false
    # @s3_object_key_format = "%{path}/%{time_slice}_%{hms_slice}.%{file_extension}"
    setup_s3_object_mocks_hardened_policy()

    # We must use TimeSlicedOutputTestDriver instead of BufferedOutputTestDriver,
    # to make assertions on chunks' keys
    config = CONFIG_TIME_SLICE.gsub(/check_object true/, "check_object false\n")
    config = config.gsub(/check_bucket true/, "check_bucket false\n")
    d = create_time_sliced_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # Finally, the instance of S3Output is initialized and then invoked
    d.run
    Zlib::GzipReader.open(s3_local_file_path) do |gz|
      data = gz.read
      assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] +
                   %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n],
                   data
    end
    FileUtils.rm_f(s3_local_file_path)
  end

  def test_write_with_custom_s3_object_key_format
    # Partial mock the S3Bucket, not to make an actual connection to Amazon S3
    setup_mocks(true)
    s3_local_file_path = "/tmp/s3-test.txt"
    setup_s3_object_mocks(s3_local_file_path: s3_local_file_path)

    # We must use TimeSlicedOutputTestDriver instead of BufferedOutputTestDriver,
    # to make assertions on chunks' keys
    d = create_time_sliced_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # Finally, the instance of S3Output is initialized and then invoked
    d.run
    Zlib::GzipReader.open(s3_local_file_path) do |gz|
      data = gz.read
      assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] +
                   %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n],
                   data
    end
    FileUtils.rm_f(s3_local_file_path)
  end

  def test_write_with_custom_s3_object_key_format_containing_uuid_flush_placeholder

    begin
      require 'uuidtools'
    rescue LoadError
      pend("uuidtools not found. skip this test")
    end

    # Partial mock the S3Bucket, not to make an actual connection to Amazon S3
    setup_mocks(true)

    uuid = "5755e23f-9b54-42d8-8818-2ea38c6f279e"
    stub(::UUIDTools::UUID).random_create{ uuid }

    s3_local_file_path = "/tmp/s3-test.txt"
    s3path = "log/events/ts=20110102-13/events_0-#{uuid}.gz"
    setup_s3_object_mocks(s3_local_file_path: s3_local_file_path, s3path: s3path)

    # We must use TimeSlicedOutputTestDriver instead of BufferedOutputTestDriver,
    # to make assertions on chunks' keys
    config = CONFIG_TIME_SLICE.gsub(/%{hostname}/,"%{uuid_flush}")
    d = create_time_sliced_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # Finally, the instance of S3Output is initialized and then invoked
    d.run
    Zlib::GzipReader.open(s3_local_file_path) do |gz|
      data = gz.read
      assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] +
                   %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n],
                   data
    end
    FileUtils.rm_f(s3_local_file_path)
    Dir.glob('tmp/*').each {|file| FileUtils.rm_f(file) }
  end

  # ToDo: need to test hex_random does not change on retry, but it is difficult with
  # the current fluentd test helper because it does not provide a way to run with the same chunks
  def test_write_with_custom_s3_object_key_format_containing_hex_random_placeholder
    unique_hex = "5226c3c4fb3d49b15226c3c4fb3d49b1"
    hex_random = unique_hex.reverse[0...5]

    config = CONFIG_TIME_SLICE.gsub(/%{hostname}/,"%{hex_random}") << "\nhex_random_length #{hex_random.length}"
    config = config.gsub(/buffer_type memory/, "buffer_type file\nbuffer_path test/tmp/buf")

    # Partial mock the S3Bucket, not to make an actual connection to Amazon S3
    setup_mocks(true)

    s3path = "log/events/ts=20110102-13/events_0-#{hex_random}.gz"
    s3_local_file_path = "/tmp/s3-test.txt"
    setup_s3_object_mocks(s3_local_file_path: s3_local_file_path, s3path: s3path)

    d = create_time_sliced_driver(config)
    stub(d.instance).unique_hex { unique_hex }

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # Finally, the instance of S3Output is initialized and then invoked
    d.run
    Zlib::GzipReader.open(s3_local_file_path) do |gz|
      data = gz.read
      assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] +
                   %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n],
                   data
    end
    FileUtils.rm_f(s3_local_file_path)
  end

  def setup_mocks(exists_return = false)
    @s3_client = stub(Aws::S3::Client.new(:stub_responses => true))
    mock(Aws::S3::Client).new(anything).at_least(0) { @s3_client }
    @s3_resource = mock(Aws::S3::Resource.new(:client => @s3_client))
    mock(Aws::S3::Resource).new(:client => @s3_client) { @s3_resource }
    @s3_bucket = mock(Aws::S3::Bucket.new(:name => "test",
                                          :client => @s3_client))
    @s3_bucket.exists? { exists_return }
    @s3_object = mock(Aws::S3::Object.new(:bucket_name => "test_bucket",
                                          :key => "test",
                                          :client => @s3_client))
    @s3_bucket.object(anything).at_least(0) { @s3_object }
    @s3_resource.bucket(anything) { @s3_bucket }
  end

  def setup_s3_object_mocks(params = {})
    s3path = params[:s3path] || "log/events/ts=20110102-13/events_0-#{Socket.gethostname}.gz"
    s3_local_file_path = params[:s3_local_file_path] || "/tmp/s3-test.txt"

    # Assert content of event logs which are being sent to S3
    s3obj = stub(Aws::S3::Object.new(:bucket_name => "test_bucket",
                                     :key => "test",
                                     :client => @s3_client))
    s3obj.exists? { false }

    tempfile = File.new(s3_local_file_path, "w")
    stub(Tempfile).new("s3-", nil) { tempfile }
    s3obj.put(:body => tempfile,
              :content_type => "application/x-gzip",
              :storage_class => "STANDARD")

    @s3_bucket.object(s3path) { s3obj }
  end

  def setup_mocks_hardened_policy()
    @s3_client = stub(Aws::S3::Client.new(:stub_responses => true))
    mock(Aws::S3::Client).new(anything).at_least(0) { @s3_client }
    @s3_resource = mock(Aws::S3::Resource.new(:client => @s3_client))
    mock(Aws::S3::Resource).new(:client => @s3_client) { @s3_resource }
    @s3_bucket = mock(Aws::S3::Bucket.new(:name => "test",
                                          :client => @s3_client))
    @s3_object = mock(Aws::S3::Object.new(:bucket_name => "test_bucket",
                                          :key => "test",
                                          :client => @s3_client))
    @s3_bucket.object(anything).at_least(0) { @s3_object }
    @s3_resource.bucket(anything) { @s3_bucket }
  end

  def setup_s3_object_mocks_hardened_policy(params = {})
    s3path = params[:s3path] || "log/20110102_131415.gz"
    s3_local_file_path = params[:s3_local_file_path] || "/tmp/s3-test.txt"

    # Assert content of event logs which are being sent to S3
    s3obj = stub(Aws::S3::Object.new(:bucket_name => "test_bucket",
                                     :key => "test",
                                     :client => @s3_client))

    tempfile = File.new(s3_local_file_path, "w")
    stub(Tempfile).new("s3-", nil) { tempfile }
    s3obj.put(:body => tempfile,
              :content_type => "application/x-gzip",
              :storage_class => "STANDARD")
  end

  def test_auto_create_bucket_false_with_non_existence_bucket
    setup_mocks

    config = CONFIG_TIME_SLICE + 'auto_create_bucket false'
    d = create_time_sliced_driver(config)
    assert_raise(RuntimeError, "The specified bucket does not exist: bucket = test_bucket") {
      d.run
    }
  end

  def test_auto_create_bucket_true_with_non_existence_bucket
    setup_mocks
    @s3_resource.create_bucket(:bucket => "test_bucket")

    config = CONFIG_TIME_SLICE + 'auto_create_bucket true'
    d = create_time_sliced_driver(config)
    assert_nothing_raised { d.run }
  end

  def test_credentials
    d = create_time_sliced_driver
    assert_nothing_raised{ d.run }
    client = d.instance.instance_variable_get(:@s3).client
    credentials = client.config.credentials
    assert_instance_of(Aws::Credentials, credentials)
  end

  def test_assume_role_credentials
    expected_credentials = Aws::Credentials.new("test_key", "test_secret")
    mock(Aws::AssumeRoleCredentials).new(:role_arn => "test_arn",
                                         :role_session_name => "test_session"){
      expected_credentials
    }
    config = CONFIG_TIME_SLICE.split("\n").reject{|x| x =~ /.+aws_.+/}.join("\n")
    config += %[
      <assume_role_credentials>
        role_arn test_arn
        role_session_name test_session
      </assume_role_credentials>
    ]
    d = create_time_sliced_driver(config)
    assert_nothing_raised{ d.run }
    client = d.instance.instance_variable_get(:@s3).client
    credentials = client.config.credentials
    assert_equal(expected_credentials, credentials)
  end

  def test_assume_role_credentials_with_region
    expected_credentials = Aws::Credentials.new("test_key", "test_secret")
    sts_client = Aws::STS::Client.new(:region => 'ap-northeast-1')
    mock(Aws::STS::Client).new(:region => 'ap-northeast-1'){ sts_client }
    mock(Aws::AssumeRoleCredentials).new(:role_arn => "test_arn",
                                         :role_session_name => "test_session",
                                         :client => sts_client){
      expected_credentials
    }
    config = CONFIG_TIME_SLICE.split("\n").reject{|x| x =~ /.+aws_.+/}.join("\n")
    config += %[
      s3_region ap-northeast-1
      <assume_role_credentials>
        role_arn test_arn
        role_session_name test_session
      </assume_role_credentials>
    ]
    d = create_time_sliced_driver(config)
    assert_nothing_raised{ d.run }
    client = d.instance.instance_variable_get(:@s3).client
    credentials = client.config.credentials
    assert_equal(expected_credentials, credentials)
  end

  def test_instance_profile_credentials
    expected_credentials = Aws::Credentials.new("test_key", "test_secret")
    mock(Aws::InstanceProfileCredentials).new({}).returns(expected_credentials)
    config = CONFIG_TIME_SLICE.split("\n").reject{|x| x =~ /.+aws_.+/}.join("\n")
    config += %[
      <instance_profile_credentials>
      </instance_profile_credentials>
    ]
    d = create_time_sliced_driver(config)
    assert_nothing_raised{ d.run }
    client = d.instance.instance_variable_get(:@s3).client
    credentials = client.config.credentials
    assert_equal(expected_credentials, credentials)
  end

  def test_ecs_credentials
    ENV["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"] = "/credential_provider_version/credentials?id=task_UUID"

    expected_credentials = Aws::Credentials.new("test_key", "test_secret")
    mock(Aws::ECSCredentials).new({}).returns(expected_credentials)
    config = CONFIG_TIME_SLICE.split("\n").reject{|x| x =~ /.+aws_.+/}.join("\n")
    config += %[
      <instance_profile_credentials>
      </instance_profile_credentials>
    ]
    d = create_time_sliced_driver(config)
    assert_nothing_raised{ d.run }
    client = d.instance.instance_variable_get(:@s3).client
    credentials = client.config.credentials
    assert_equal(expected_credentials, credentials)

    ENV["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"] = nil
  end

  def test_instance_profile_credentials_aws_iam_retries
    expected_credentials = Aws::Credentials.new("test_key", "test_secret")
    mock(Aws::InstanceProfileCredentials).new({}).returns(expected_credentials)
    config = CONFIG_TIME_SLICE.split("\n").reject{|x| x =~ /.+aws_.+/}.join("\n")
    config += %[
      aws_iam_retries 10
    ]
    d = create_time_sliced_driver(config)
    assert_nothing_raised{ d.run }
    client = d.instance.instance_variable_get(:@s3).client
    credentials = client.config.credentials
    assert_equal(expected_credentials, credentials)
  end

  def test_shared_credentials
    expected_credentials = Aws::Credentials.new("test_key", "test_secret")
    mock(Aws::SharedCredentials).new({}).returns(expected_credentials)
    config = CONFIG_TIME_SLICE.split("\n").reject{|x| x =~ /.+aws_.+/}.join("\n")
    config += %[
      <shared_credentials>
      </shared_credentials>
    ]
    d = create_time_sliced_driver(config)
    assert_nothing_raised{ d.run }
    client = d.instance.instance_variable_get(:@s3).client
    credentials = client.config.credentials
    assert_equal(expected_credentials, credentials)
  end

  def test_signature_version
    config = [CONFIG, 'signature_version s3'].join("\n")
    d = create_driver(config)

    signature_version = d.instance.instance_variable_get(:@signature_version)
    assert_equal("s3", signature_version)
  end

  def test_warn_for_delay
    setup_mocks(true)
    s3_local_file_path = "/tmp/s3-test.txt"
    setup_s3_object_mocks(s3_local_file_path: s3_local_file_path)

    config = CONFIG_TIME_SLICE + 'warn_for_delay 1d'
    d = create_time_sliced_driver(config)

    delayed_time = Time.parse("2011-01-02 13:14:15 UTC")
    now = delayed_time + 86000 + 1
    Timecop.freeze(now)

    d.emit({"a"=>1}, delayed_time.to_i)
    d.emit({"a"=>2}, delayed_time.to_i)

    d.run

    logs = d.instance.log.logs
    assert_true logs.any? {|log| log.include?('out_s3: delayed events were put') }

    Timecop.return
    FileUtils.rm_f(s3_local_file_path)
  end
end
