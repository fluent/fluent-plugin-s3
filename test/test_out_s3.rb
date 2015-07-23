require 'fluent/test'
require 'fluent/plugin/out_s3'

require 'test/unit/rr'
require 'zlib'

class S3OutputTest < Test::Unit::TestCase
  def setup
    require 'aws-sdk-resources'
    Fluent::Test.setup
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
    Fluent::Test::BufferedOutputTestDriver.new(Fluent::S3Output) do
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
                 data
  end

  CONFIG_TIME_SLICE = %[
    hostname testing.node.local
    aws_key_id test_key_id
    aws_sec_key test_sec_key
    s3_bucket test_bucket
    s3_object_key_format %{path}/events/ts=%{time_slice}/events_%{index}-%{hostname}.%{file_extension}
    time_slice_format %Y%m%d-%H
    path log
    utc
    buffer_type memory
    log_level debug
  ]

  def create_time_sliced_driver(conf = CONFIG_TIME_SLICE)
    d = Fluent::Test::TimeSlicedOutputTestDriver.new(Fluent::S3Output) do
      private

      def check_apikeys
      end
    end.configure(conf)
    d
  end

  def test_write_with_custom_s3_object_key_format
    # Assert content of event logs which are being sent to S3
    s3obj = flexmock(Aws::S3::S3Object)
    s3obj.should_receive(:exists?).with_any_args.and_return { false }
    s3obj.should_receive(:write).with(
      on { |pathname|
        data = nil
        # Event logs are compressed in GZip
        pathname.open { |f|
          gz = Zlib::GzipReader.new(f)
          data = gz.read
          gz.close
        }
        assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] +
                     %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n],
                     data

        pathname.to_s.match(%r|s3-|)
      },
      {:content_type => "application/x-gzip", :reduced_redundancy => false, :acl => :private})

    # Assert the key of S3Object, which event logs are stored in
    s3obj_col = flexmock(Aws::S3::ObjectCollection)
    s3obj_col.should_receive(:[]).with(
      on { |key|
        key == "log/events/ts=20110102-13/events_0-testing.node.local.gz"
      }).
      and_return {
        s3obj
      }

    # Partial mock the S3Bucket, not to make an actual connection to Amazon S3
    s3bucket, _ = setup_mocks(true)
    s3bucket.should_receive(:objects).with_any_args.and_return { s3obj_col }

    # We must use TimeSlicedOutputTestDriver instead of BufferedOutputTestDriver,
    # to make assertions on chunks' keys
    d = create_time_sliced_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # Finally, the instance of S3Output is initialized and then invoked
    d.run
  end

  def test_write_with_custom_s3_object_key_format_containing_uuid_flush_placeholder
    # Assert content of event logs which are being sent to S3
    s3obj = flexmock(AWS::S3::S3Object)
    s3obj.should_receive(:exists?).with_any_args.and_return { false }
    s3obj.should_receive(:write).with(
      on { |pathname|
        data = nil
        # Event logs are compressed in GZip
        pathname.open { |f|
          gz = Zlib::GzipReader.new(f)
          data = gz.read
          gz.close
        }
        assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] +
                     %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n],
                     data

        pathname.to_s.match(%r|s3-|)
      },
      {:content_type => "application/x-gzip", :reduced_redundancy => false, :acl => :private})

    # Assert the key of S3Object, which event logs are stored in
    s3obj_col = flexmock(AWS::S3::ObjectCollection)
    s3obj_col.should_receive(:[]).with(
      on { |key|
        key =~ /.*.[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}.*/
      }).
      and_return {
        s3obj
      }

    # Partial mock the S3Bucket, not to make an actual connection to Amazon S3
    s3bucket, _ = setup_mocks(true)
    s3bucket.should_receive(:objects).with_any_args.and_return { s3obj_col }

    # We must use TimeSlicedOutputTestDriver instead of BufferedOutputTestDriver,
    # to make assertions on chunks' keys
    config = CONFIG_TIME_SLICE.clone.gsub(/%{hostname}/,"%{uuid_flush}")
    d = create_time_sliced_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # Finally, the instance of S3Output is initialized and then invoked
    d.run
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
end
