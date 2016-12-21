require 'aws-sdk-resources'

require 'fluent/test'
require 'fluent/plugin/in_s3'

require 'test/unit/rr'
require 'zlib'
require 'fileutils'

class S3InputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @time = Time.parse("2015-09-30 13:14:15 UTC").to_i
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
    </sqs>
  ]

  def create_driver(conf = CONFIG)
    d = Fluent::Test::InputTestDriver.new(Fluent::S3Input)
    d.configure(conf)
    d
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
      assert_raise(Fluent::ConfigError) do
        create_driver(config)
      end
    end

    data("json" => ["json", "json", "application/json"],
         "text" => ["text", "txt", "text/plain"],
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

  Struct.new("StubResponse", :queue_url)
  Struct.new("StubMessage", :message_id, :receipt_handle, :body)

  def setup_mocks
    @s3_client = stub(Aws::S3::Client.new(:stub_responses => true))
    mock(Aws::S3::Client).new(anything).at_least(0) { @s3_client }
    @s3_resource = mock(Aws::S3::Resource.new(:client => @s3_client))
    mock(Aws::S3::Resource).new(:client => @s3_client) { @s3_resource }
    @s3_bucket = mock(Aws::S3::Bucket.new(:name => "test",
                                          :client => @s3_client))
    @s3_resource.bucket(anything) { @s3_bucket }

    test_queue_url = "http://example.com/test_queue"
    @sqs_client = stub(Aws::SQS::Client.new(:stub_responses => true))
    @sqs_response = stub(Struct::StubResponse.new(test_queue_url))
    @sqs_client.get_queue_url(queue_name: "test_queue"){ @sqs_response }
    mock(Aws::SQS::Client).new(anything).at_least(0) { @sqs_client }
    @real_poller = Aws::SQS::QueuePoller.new(test_queue_url, client: @sqs_client)
    @sqs_poller = stub(@real_poller)
    mock(Aws::SQS::QueuePoller).new(anything, client: @sqs_client) { @sqs_poller }
  end

  def test_no_records
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\n")
    mock(d.instance).process(anything).never

    message = Struct::StubMessage.new(1, 1, "{}")
    @sqs_poller.get_messages {|config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count > 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    }
    assert_nothing_raised do
      d.run
    end
  end

  def test_one_record
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\n")
    d.expect_emit("input.s3", @time, { "message" => "aaa" })

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
    message = Struct::StubMessage.new(1, 1, Yajl.dump(body))
    @sqs_poller.get_messages {|config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count > 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    }
    assert_nothing_raised do
      d.run
    end
  end

  def test_one_record_multi_line
    setup_mocks
    d = create_driver(CONFIG + "\ncheck_apikey_on_start false\nstore_as text\nformat none\n")
    d.expect_emit("input.s3", @time, { "message" => "aaa\n" })
    d.expect_emit("input.s3", @time, { "message" => "bbb\n" })
    d.expect_emit("input.s3", @time, { "message" => "ccc\n" })

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
    message = Struct::StubMessage.new(1, 1, Yajl.dump(body))
    @sqs_poller.get_messages {|config, stats|
      config.before_request.call(stats) if config.before_request
      stats.request_count += 1
      if stats.request_count > 1
        d.instance.instance_variable_set(:@running, false)
      end
      [message]
    }
    assert_nothing_raised do
      d.run
    end
  end
end
