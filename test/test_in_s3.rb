require 'aws-sdk-s3'
require 'aws-sdk-sqs'
require 'aws-sdk-sqs/queue_poller'

require 'fluent/test'
require 'fluent/test/helpers'
require 'fluent/test/log'
require 'fluent/test/driver/input'
require 'fluent/plugin/in_s3'

require 'test/unit/rr'
require 'zlib'
require 'fileutils'
require 'ostruct'

include Fluent::Test::Helpers

class S3InputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @time = event_time("2015-09-30 13:14:15 UTC")
    Fluent::Engine.now = @time
    if Fluent.const_defined?(:EventTime)
      stub(Fluent::EventTime).now { @time }
    end
  end

  CONFIG = %[
    aws_key_id test_key_id
    aws_sec_key test_sec_key
    s3_bucket test_bucket
    buffer_type memory
    <sqs>
      queue_name test_queue
      queue_owner_aws_account_id 123456789123
    </sqs>
  ]

  def create_driver(conf = CONFIG)
    Fluent::Test::Driver::Input.new(Fluent::Plugin::S3Input).configure(conf)
  end

  class ConfigTest < self
    def test_default
      d = create_driver
      extractor = d.instance.instance_variable_get(:@extractor)
      actual = {
        aws_key_id: d.instance.aws_key_id,
        aws_sec_key: d.instance.aws_sec_key,
        s3_bucket: d.instance.s3_bucket,
        s3_region: d.instance.s3_region,
        sqs_queue_name: d.instance.sqs.queue_name,
        extractor_ext: extractor.ext,
        extractor_content_type: extractor.content_type
      }
      expected = {
        aws_key_id: "test_key_id",
        aws_sec_key: "test_sec_key",
        s3_bucket: "test_bucket",
        s3_region: "us-east-1",
        sqs_queue_name: "test_queue",
        extractor_ext: "gz",
        extractor_content_type: "application/x-gzip"
      }
      assert_equal(expected, actual)
    end

    def test_empty
      assert_raise(Fluent::ConfigError) do
        create_driver("")
      end
    end

    def test_aws_profile
      d = create_driver(%[
        aws_profile test_profile
        s3_bucket test_bucket
        buffer_type memory
        <sqs>
          queue_name test_queue
          queue_owner_aws_account_id 123456789123
        </sqs>
      ])
      assert_equal 'test_profile', d.instance.aws_profile
    end

    def test_aws_credential_process
      d = create_driver(%[
        aws_credential_process "/path/to/aws_signing_helper credential-process"
        s3_bucket test_bucket
        buffer_type memory
        <sqs>
          queue_name test_queue
          queue_owner_aws_account_id 123456789123
        </sqs>
      ])
      assert_equal '/path/to/aws_signing_helper credential-process', d.instance.aws_credential_process
    end

    def test_without_sqs_section
      conf = %[
        aws_key_id test_key_id
        aws_sec_key test_sec_key
        s3_bucket test_bucket
      ]
      assert_raise_message("'<sqs>' sections are required") do
        create_driver(conf)
      end
    end

    def test_unknown_store_as
      config = CONFIG + "\nstore_as unknown"
      assert_raise(Fluent::NotFoundPluginError) do
        create_driver(config)
      end
    end

    data("json" => ["json", "json", "application/json"],
         "text" => ["text", "txt", "text/plain"],
         "gzip" => ["gzip", "gz", "application/x-gzip"],
         "gzip_command" => ["gzip_command", "gz", "application/x-gzip"],
         "lzo" => ["lzo", "lzo", "application/x-lzop"],
         "lzma2" => ["lzma2", "xz", "application/x-xz"])
    def test_extractor(data)
      store_type, ext, content_type = data
      config = CONFIG + "\nstore_as #{store_type}\n"
      d = create_driver(config)
      extractor = d.instance.instance_variable_get(:@extractor)
      expected = {
        ext: ext,
        content_type: content_type
      }
      actual = {
        ext: extractor.ext,
        content_type: extractor.content_type
      }
      assert_equal(expected, actual)
    rescue Fluent::ConfigError => e
      pend(e.message)
    end
  end


  data('Normal endpoint' => 'riak-cs.example.com',
       'VPCE endpoint' => 'vpce.amazonaws.com',
       'FIPS endpoint' => 'fips.xxx.amazonaws.com',
       'GOV endpoint' => 'gov.xxx.amazonaws.com')
  def test_s3_endpoint_with_valid_endpoint(endpoint)
    d = create_driver(CONFIG + "s3_endpoint #{endpoint}")
    assert_equal endpoint, d.instance.s3_endpoint
  end

  data('US West (Oregon)' => 's3-us-west-2.amazonaws.com',
       'EU (Frankfurt)' => 's3.eu-central-1.amazonaws.com',
       'Asia Pacific (Tokyo)' => 's3-ap-northeast-1.amazonaws.com',
       'Invalid VPCE' => 'vpce.xxx.amazonaws.com')
  def test_s3_endpoint_with_invalid_endpoint(endpoint)
    assert_raise(Fluent::ConfigError, "s3_endpoint parameter is not supported, use s3_region instead. This parameter is for S3 compatible services") {
      create_driver(CONFIG + "s3_endpoint #{endpoint}")
    }
  end

  data('US West (Oregon)' => 's3-us-west-2.amazonaws.com',
       'EU (Frankfurt)' => 's3.eu-central-1.amazonaws.com',
       'Asia Pacific (Tokyo)' => 's3-ap-northeast-1.amazonaws.com')
  def test_sqs_endpoint_with_invalid_endpoint(endpoint)
    assert_raise(Fluent::ConfigError, "sqs.endpoint parameter is not supported, use s3_region instead. This parameter is for SQS compatible services") {
      conf = <<"EOS"
aws_key_id test_key_id
aws_sec_key test_sec_key
s3_bucket test_bucket
buffer_type memory
<sqs>
  queue_name test_queue
  endpoint #{endpoint}
</sqs>
EOS
      create_driver(conf)
    }
  end

  def test_sqs_with_invalid_keys_missing_secret_key
    assert_raise(Fluent::ConfigError, "sqs/aws_key_id or sqs/aws_sec_key is missing") {
      conf = <<"EOS"
aws_key_id test_key_id
aws_sec_key test_sec_key
s3_bucket test_bucket
buffer_type memory
<sqs>
  queue_name test_queue
  endpoint eu-west-1
  aws_key_id sqs_test_key_id
</sqs>
EOS
      create_driver(conf)
    }
  end

  def test_sqs_with_invalid_aws_keys_missing_key_id
    assert_raise(Fluent::ConfigError, "sqs/aws_key_id or sqs/aws_sec_key is missing") {
      conf = <<"EOS"
aws_key_id test_key_id
aws_sec_key test_sec_key
s3_bucket test_bucket
buffer_type memory
<sqs>
  queue_name test_queue
  endpoint eu-west-1
  aws_sec_key sqs_test_sec_key
</sqs>
EOS
      create_driver(conf)
    }
  end

  def test_sqs_with_valid_aws_keys_complete_pair
    conf = <<"EOS"
aws_key_id test_key_id
aws_sec_key test_sec_key
s3_bucket test_bucket
buffer_type memory
<sqs>
  queue_name test_queue
  endpoint eu-west-1
  aws_key_id sqs_test_key_id
  aws_sec_key sqs_test_sec_key
</sqs>
EOS
    d = create_driver(conf)
    assert_equal 'sqs_test_key_id', d.instance.sqs.aws_key_id
    assert_equal 'sqs_test_sec_key', d.instance.sqs.aws_sec_key
  end

  def test_with_invalid_aws_keys_missing_secret_key
    assert_raise(Fluent::ConfigError, "aws_key_id or aws_sec_key is missing") {
      conf = <<"EOS"
aws_key_id test_key_id
s3_bucket test_bucket
buffer_type memory
<sqs>
  queue_name test_queue
  endpoint eu-west-1
</sqs>
EOS
      create_driver(conf)
    }
  end

  def test_with_invalid_aws_keys_missing_key_id
    assert_raise(Fluent::ConfigError, "aws_key_id or aws_sec_key is missing") {
      conf = <<"EOS"
aws_sec_key test_sec_key
s3_bucket test_bucket
buffer_type memory
<sqs>
  queue_name test_queue
  endpoint eu-west-1
</sqs>
EOS
      create_driver(conf)
    }
  end

  def test_with_valid_aws_keys_complete_pair
    conf = <<"EOS"
aws_key_id test_key_id
aws_sec_key test_sec_key
s3_bucket test_bucket
buffer_type memory
<sqs>
  queue_name test_queue
  endpoint eu-west-1
</sqs>
EOS
    d = create_driver(conf)
    assert_equal 'test_key_id', d.instance.aws_key_id
    assert_equal 'test_sec_key', d.instance.aws_sec_key
  end

  Struct.new("StubResponse", :queue_url)
  Struct.new("StubMessage", :message_id, :receipt_handle, :body)

  def setup_mocks
    @s3_client = stub(Aws::S3::Client.new(stub_responses: true))
    stub(@s3_client).config { OpenStruct.new({region: "us-east-1"}) }
    mock(Aws::S3::Client).new(anything).at_least(0) { @s3_client }
    @s3_resource = mock(Aws::S3::Resource.new(client: @s3_client))
    mock(Aws::S3::Resource).new(client: @s3_client) { @s3_resource }
    @s3_bucket = mock(Aws::S3::Bucket.new(name: "test",
                                          client: @s3_client))
    @s3_bucket.exists? { true }
    @s3_resource.bucket(anything) { @s3_bucket }

    test_queue_url = "http://example.com/test_queue"
    @sqs_client = stub(Aws::SQS::Client.new(stub_responses: true))
    @sqs_response = stub(Struct::StubResponse.new(test_queue_url))
    @sqs_client.get_queue_url(queue_name: "test_queue", queue_owner_aws_account_id: "123456789123"){ @sqs_response }
    mock(Aws::SQS::Client).new(anything).once { @sqs_client }
    @real_poller = Aws::SQS::QueuePoller.new(test_queue_url, client: @sqs_client)
    @sqs_poller = stub(@real_poller)
    mock(Aws::SQS::QueuePoller).new(anything, client: @sqs_client) { @sqs_poller }
  end

  def test_no_records
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\n")
    mock(d.instance).process(anything).never

    message = Struct::StubMessage.new(1, 1, "{}")
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count > 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    assert_nothing_raised do
      d.run {}
    end
  end

  def test_one_record
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\n")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa") }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    assert_equal({ "message" => "aaa" }, events.first[2])
  end

  def test_one_record_with_metadata
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\nadd_object_metadata true\n")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa") }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    assert_equal({ "s3_bucket" => "test_bucket", "s3_key" => "test_key", "message" => "aaa" }, events.first[2])
  end

  def test_one_record_url_encoded
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\n")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa") }
    s3_object.get { s3_response }
    @s3_bucket.object('test key').at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test+key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    assert_equal({ "message" => "aaa" }, events.first[2])
  end

  def test_one_record_url_encoded_with_metadata
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\nadd_object_metadata true")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa") }
    s3_object.get { s3_response }
    @s3_bucket.object('test key').at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test+key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    assert_equal({ "s3_bucket" => "test_bucket", "s3_key" => "test+key", "message" => "aaa" }, events.first[2])
  end

  def test_one_record_multi_line
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\n")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa\nbbb\nccc\n") }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    expected_records = [
      { "message" => "aaa\n" },
      { "message" => "bbb\n" },
      { "message" => "ccc\n" }
    ]
    assert_equal(expected_records, events.map {|_tag, _time, record| record })
  end

  def test_one_record_multi_line_with_metadata
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\nadd_object_metadata true")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa\nbbb\nccc\n") }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    expected_records = [
      { "s3_bucket" => "test_bucket", "s3_key" => "test_key", "message" => "aaa\n" },
      { "s3_bucket" => "test_bucket", "s3_key" => "test_key", "message" => "bbb\n" },
      { "s3_bucket" => "test_bucket", "s3_key" => "test_key", "message" => "ccc\n" }
    ]
    assert_equal(expected_records, events.map {|_tag, _time, record| record })
  end

  def test_gzip_single_stream
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as gzip\nformat none\n")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body {
      io = StringIO.new
      Zlib::GzipWriter.wrap(io) do |gz|
        gz.write "aaa\nbbb\n"
        gz.finish
      end
      io.rewind
      io
    }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    expected_records = [
      { "message" => "aaa\n" },
      { "message" => "bbb\n" }
    ]
    assert_equal(expected_records, events.map {|_tag, _time, record| record })
  end

  def test_gzip_multiple_steams
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as gzip\nformat none\n")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body {
      io = StringIO.new
      Zlib::GzipWriter.wrap(io) do |gz|
        gz.write "aaa\nbbb\n"
        gz.finish
      end
      Zlib::GzipWriter.wrap(io) do |gz|
        gz.write "ccc\nddd\n"
        gz.finish
      end
      io.rewind
      io
    }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    expected_records = [
      { "message" => "aaa\n" },
      { "message" => "bbb\n" },
      { "message" => "ccc\n" },
      { "message" => "ddd\n" }
    ]
    assert_equal(expected_records, events.map {|_tag, _time, record| record })
  end

  data(
    "limit_gzip"          => { type: "gzip",         input: "StringIO", limit: 10,  expected_error: true },
    "limit_text"          => { type: "text",         input: "StringIO", limit: 10,  expected_error: true },
    "limit_gzip_command1" => { type: "gzip_command", input: "StringIO", limit: 10,  expected_error: true },
    "limit_gzip_command2" => { type: "gzip_command", input: "Tempfile", limit: 10,  expected_error: true },
    "normal_gzip_command" => { type: "gzip_command", input: "Tempfile", limit: 100, expected_error: false },
    )
  def test_decompression_size_limit(data)
    store_type = data[:type]
    input_type = data[:input]
    limit = data[:limit]
    setup_mocks

    config = <<~CONF
      #{CONFIG}
      check_apikey_on_start false
      store_as #{store_type}
      format none
      decompression_size_limit #{limit}
    CONF

    d = create_driver(config)

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body {
      content = "#{'a'*10}\n#{'b'*10}\n"

      # Switching between Tempfile and StringIO to cover both branches of the
      # `io.respond_to?(:path)` condition in `extract_with_command`.
      # This ensures that:
      # 1. The StringIO route correctly uses TextExtractor to create a protected temporary file.
      # 2. The Tempfile route correctly limits the output size during Open3.popen3 execution.
      io = (input_type == "Tempfile") ? Tempfile.new : StringIO.new

      case store_type
      when "gzip", "gzip_command"
        io.binmode
        Zlib::GzipWriter.wrap(io) { |gz|
          gz.write content
          gz.finish
        }
      when "text"
        io.write content
      end

      io.rewind
      io
    }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, Yajl.dump(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run

    if data[:expected_error]
      # Verify the protection mechanism: ensure SizeLimitError is logged.
      assert_true d.logs.any? { |l| l.include?("Extracted data exceeds limit of #{limit} bytes") }
    else
      # Verify the normal execution path: ensure data is correctly extracted via Open3.popen3.
      expected_records = [{ "message" => "#{'a'*10}\n" }, { "message" => "#{'b'*10}\n" }]
      assert_equal(expected_records, d.events.map {|_tag, _time, record| record })
      assert_false d.logs.any? { |l| l.include?("error_class") }
    end
  end

  def test_regexp_matching
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\nmatch_regexp .*_key?")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa bbb ccc") }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    assert_equal({ "message" => "aaa bbb ccc" }, events.first[2])
  end

  def test_regexp_not_matching
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\nmatch_regexp live?_key")

    body = {
      "Records" => [
        {
          "s3" => {
            "object" => {
              "key" => "test_key"
            }
          }
        }
      ]
    }
    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    assert_nothing_raised do
      d.run {}
    end
  end

  def test_event_bridge_mode
    setup_mocks
    d = create_driver("
      aws_key_id test_key_id
      aws_sec_key test_sec_key
      s3_bucket test_bucket
      buffer_type memory
      check_apikey_on_start false
      store_as text
      format none
      <sqs>
        event_bridge_mode true
        queue_name test_queue
        queue_owner_aws_account_id 123456789123
      </sqs>
    ")

    s3_object = stub(Object.new)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new("aaa") }
    s3_object.get { s3_response }
    @s3_bucket.object(anything).at_least(1) { s3_object }

    body = {
      "detail" => {
        "object" => {
          "key" => "test_key"
        }
      }
    }

    message = Struct::StubMessage.new(1, 1, JSON.generate(body))
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    d.run(expect_emits: 1)
    events = d.events
    assert_equal({ "message" => "aaa" }, events.first[2])
  end

  POLL_CONFIG = CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\n"

  EVENT_BRIDGE_POLL_CONFIG =
    CONFIG.sub("<sqs>", "<sqs>\n      event_bridge_mode true") +
    "\ncheck_apikey_on_start false\nstore_as text\nformat none\n"

  def notification(key)
    JSON.generate({ "Records" => [{ "s3" => { "object" => { "key" => key } } }] })
  end

  def gzipped(text)
    buffer = StringIO.new(String.new, "wb")
    Zlib::GzipWriter.wrap(buffer) { |gz| gz.write(text) }
    buffer.string
  end

  def stub_s3_object(payload: "aaa", get_error: nil)
    s3_response = stub(Object.new)
    s3_response.body { StringIO.new(payload) }
    s3_object = stub(Object.new)
    s3_object.get { raise get_error if get_error; s3_response }
    @s3_bucket.object(anything).at_least(0) do |key|
      raise ArgumentError, ":key must not be blank" if key.to_s.empty?
      raise ArgumentError, "invalid byte sequence in UTF-8" unless key.to_s.valid_encoding?
      s3_object
    end
  end

  def poll_once(d, message)
    deleted = []
    @sqs_poller.delete_messages(anything) { |messages| deleted.concat(messages) }
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    end
    deleted
  end

  def warn_logs(d)
    d.logs.select { |log| log.include?("[warn]") }
  end

  data(
    "body is not JSON" => "hello",
    "body is empty" => "",
    "body is not a JSON object" => "[]",
    "body is null" => "null",
    "Records is empty" => '{"Records":[]}',
    "record without s3" => '{"Records":[{}]}',
    "record without object" => '{"Records":[{"s3":{}}]}',
    "record without key" => '{"Records":[{"s3":{"object":{}}}]}',
    "Records is a string" => '{"Records":"test_key"}',
    "Records is an object" => '{"Records":{"s3":{}}}',
    "key is not a string" => '{"Records":[{"s3":{"object":{"key":1}}}]}',
    "key is empty" => '{"Records":[{"s3":{"object":{"key":""}}}]}',
    "key holds invalid utf-8" => %Q({"Records":[{"s3":{"object":{"key":"a\xFF\xFEb"}}}]}),
    "key decodes to invalid utf-8" => '{"Records":[{"s3":{"object":{"key":"%FF"}}}]}',
  )
  def test_unrecoverable_message_is_deleted(body)
    setup_mocks
    stub_s3_object
    d = create_driver(POLL_CONFIG)

    message = Struct::StubMessage.new(1, 1, body)
    deleted = poll_once(d, message)

    assert_nothing_raised { d.run {} }
    assert_equal([message], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?("Skipping SQS message") })
  end

  def test_unrecoverable_message_in_event_bridge_mode_is_deleted
    setup_mocks
    stub_s3_object
    d = create_driver(EVENT_BRIDGE_POLL_CONFIG)

    message = Struct::StubMessage.new(1, 1, '{"detail":{}}')
    deleted = poll_once(d, message)

    assert_nothing_raised { d.run {} }
    assert_equal([message], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?("Skipping SQS message") })
  end

  data(
    "no Records property" => "{}",
    "sns envelope" => '{"Type":"Notification","Message":"{}"}',
    "s3 test event" => '{"Service":"Amazon S3","Event":"s3:TestEvent"}',
  )
  def test_message_that_is_not_an_s3_notification_is_reported(body)
    setup_mocks
    stub_s3_object
    d = create_driver(POLL_CONFIG)
    mock(d.instance).process(anything).never

    message = Struct::StubMessage.new(1, 1, body)
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([message], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?("not an S3 notification") })
  end

  data(
    "missing object" => "NoSuchKey",
    "missing bucket" => "NoSuchBucket",
    "access denied" => "AccessDenied",
    "throttled" => "SlowDown",
  )
  def test_service_error_keeps_the_message_for_redelivery(error_name)
    setup_mocks
    stub_s3_object(get_error: Aws::S3::Errors.const_get(error_name).new(nil, error_name))
    d = create_driver(POLL_CONFIG)

    message = Struct::StubMessage.new(1, 1, notification("test_key"))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?("Failed to handle SQS message") })
  end

  def test_networking_error_keeps_the_message_for_redelivery
    setup_mocks
    stub_s3_object(get_error: Seahorse::Client::NetworkingError.new(Errno::ECONNRESET.new))
    d = create_driver(POLL_CONFIG)

    message = Struct::StubMessage.new(1, 1, notification("test_key"))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([], deleted)
  end

  data(
    "gzip" => "gzip",
    "gzip_command" => "gzip_command",
    "lzo" => "lzo",
    "lzma2" => "lzma2",
  )
  def test_corrupt_archive_is_deleted(store_type)
    setup_mocks
    stub_s3_object(payload: "this is not an archive")
    begin
      d = create_driver(POLL_CONFIG.sub("store_as text", "store_as #{store_type}"))
    rescue Fluent::ConfigError => e
      pend(e.message)
    end

    message = Struct::StubMessage.new(1, 1, notification("test_key"))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([message], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?("Skipping SQS message") })
  end

  def test_object_over_the_decompression_limit_is_deleted
    setup_mocks
    stub_s3_object(payload: gzipped("a" * 100))
    d = create_driver(POLL_CONFIG.sub("store_as text", "store_as gzip") + "\ndecompression_size_limit 10\n")

    message = Struct::StubMessage.new(1, 1, notification("test_key"))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([message], deleted)
    assert_true(d.logs.any? { |log| log.include?("Extracted data exceeds limit") })
  end

  def test_unrecoverable_message_is_not_redelivered
    setup_mocks
    stub_s3_object
    d = create_driver(POLL_CONFIG)

    deleted = []
    attempts = 0
    @sqs_poller.delete_messages(anything) { |messages| deleted.concat(messages) }
    message = Struct::StubMessage.new("mid-1", "rh-1", '{"Records":[]}')
    @sqs_poller.get_messages(anything, anything) do |config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count >= 5
        d.instance.instance_variable_set(:@running, false)
      end
      next [] unless deleted.empty?
      attempts += 1
      [message]
    end
    d.run {}

    assert_equal([message], deleted)
    assert_equal(1, attempts)
  end

  def test_a_bug_in_the_plugin_keeps_the_message_for_redelivery
    setup_mocks
    stub_s3_object
    d = create_driver(POLL_CONFIG)
    stub(d.instance).is_valid_queue(anything) { raise NoMethodError, "undefined method 'foo' for nil" }

    message = Struct::StubMessage.new(1, 1, notification("test_key"))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?("Failed to handle SQS message") })
  end

  def test_unparsable_object_is_deleted
    setup_mocks
    stub_s3_object(payload: "\xC1")
    d = create_driver(POLL_CONFIG.sub("format none", "<parse>\n  @type msgpack\n</parse>"))

    message = Struct::StubMessage.new(1, 1, notification("test_key"))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([message], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?("Skipping SQS message") })
  end

  def test_deleting_warn_names_the_object_key
    setup_mocks
    stub_s3_object(payload: "this is not an archive")
    d = create_driver(POLL_CONFIG.sub("store_as text", "store_as gzip"))

    message = Struct::StubMessage.new(1, 1, notification("path/to/broken.gz"))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([message], deleted)
    assert_true(warn_logs(d).any? { |log| log.include?(%Q(key="path/to/broken.gz")) })
    assert_true(warn_logs(d).any? { |log| log.include?("in_s3.rb:") })
  end

  def test_deleting_warn_truncates_a_long_object_key
    setup_mocks
    stub_s3_object(payload: "this is not an archive")
    d = create_driver(POLL_CONFIG.sub("store_as text", "store_as gzip"))

    message = Struct::StubMessage.new(1, 1, notification("\u3042" * 400))
    deleted = poll_once(d, message)
    d.run {}

    assert_equal([message], deleted)
    line = warn_logs(d).find { |log| log.include?("Skipping SQS message") }
    assert_operator(line[/key="(.*)"/, 1].length, :<=, Fluent::Plugin::S3Input::LOG_MAX_BYTES)
  end

  def test_a_truncated_object_key_is_still_valid_utf8
    d = create_driver(POLL_CONFIG)
    logged = d.instance.__send__(:loggable, "\u3042" * 400)

    assert_true(logged.valid_encoding?)
    assert_operator(logged.bytesize, :<=, Fluent::Plugin::S3Input::LOG_MAX_BYTES)
    assert_nothing_raised { JSON.generate([logged]) }
  end

  def test_valid_message_is_processed_and_deleted
    setup_mocks
    stub_s3_object
    d = create_driver(POLL_CONFIG)

    message = Struct::StubMessage.new(1, 1, notification("test_key"))
    deleted = poll_once(d, message)
    d.run(expect_emits: 1)

    assert_equal([message], deleted)
    assert_equal({ "message" => "aaa" }, d.events.first[2])
    assert_equal([], warn_logs(d))
  end

end
