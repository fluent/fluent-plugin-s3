require 'fluent/test'
require 'fluent/plugin/out_s3'

require 'flexmock/test_unit'
require 'zlib'

class S3OutputTest < Test::Unit::TestCase
  def setup
    require 'aws-sdk'
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
    assert d.instance.instance_variable_get(:@use_ssl)
    assert_equal 'gz', d.instance.instance_variable_get(:@ext)
    assert_equal 'application/x-gzip', d.instance.instance_variable_get(:@mime_type)
  end

  def test_configure_with_mime_type_json
    conf = CONFIG.clone
    conf << "\nstore_as json\n"
    d = create_driver(conf)
    assert_equal 'json', d.instance.instance_variable_get(:@ext)
    assert_equal 'application/json', d.instance.instance_variable_get(:@mime_type)
  end

  def test_configure_with_mime_type_text
    conf = CONFIG.clone
    conf << "\nstore_as text\n"
    d = create_driver(conf)
    assert_equal 'txt', d.instance.instance_variable_get(:@ext)
    assert_equal 'text/plain', d.instance.instance_variable_get(:@mime_type)
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

  def test_format_with_format_json
    config = [CONFIG, 'format_json true'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[{"a":1}\n]
    d.expect_format %[{"a":2}\n]

    d.run
  end

  def test_format_with_format_json_included_tag
    config = [CONFIG, 'format_json true', 'include_tag_key true'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[{"a":1,"tag":"test"}\n]
    d.expect_format %[{"a":2,"tag":"test"}\n]

    d.run
  end

  def test_format_with_format_json_included_time
    config = [CONFIG, 'format_json true', 'include_time_key true'].join("\n")
    d = create_driver(config)

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[{"a":1,"time":"2011-01-02T13:14:15Z"}\n]
    d.expect_format %[{"a":2,"time":"2011-01-02T13:14:15Z"}\n]

    d.run
  end

  def test_format_with_format_json_included_tag_and_time
    config = [CONFIG, 'format_json true', 'include_tag_key true', 'include_time_key true'].join("\n")
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

  CONFIG2 = %[
    hostname testing.node.local
    aws_key_id test_key_id
    aws_sec_key test_sec_key
    s3_bucket test_bucket
    s3_object_key_format %{path}/events/ts=%{time_slice}/events_%{index}-%{hostname}.%{file_extension}
    time_slice_format %Y%m%d-%H
    path log
    utc
    buffer_type memory
    auto_create_bucket false
  ]

  def create_time_sliced_driver(additional_conf = '')
    d = Fluent::Test::TimeSlicedOutputTestDriver.new(Fluent::S3Output) do
      private

      def check_apikeys
      end
    end.configure([CONFIG2, additional_conf].join("\n"))
    d
  end

  def test_write_with_custom_s3_object_key_format
    # Assert content of event logs which are being sent to S3
    s3obj = flexmock(AWS::S3::S3Object)
    s3obj.should_receive(:exists?).with_any_args.
      and_return { false }
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
      {:content_type=>"application/x-gzip"})

    # Assert the key of S3Object, which event logs are stored in
    s3obj_col = flexmock(AWS::S3::ObjectCollection)
    s3obj_col.should_receive(:[]).with(
      on { |key|
        key == "log/events/ts=20110102-13/events_0-testing.node.local.gz"
      }).
      and_return {
        s3obj
      }

    # Partial mock the S3Bucket, not to make an actual connection to Amazon S3
    flexmock(AWS::S3::Bucket).new_instances do |bucket|
      bucket.should_receive(:objects).with_any_args.
        and_return {
          s3obj_col
        }
    end

    # We must use TimeSlicedOutputTestDriver instead of BufferedOutputTestDriver,
    # to make assertions on chunks' keys
    d = create_time_sliced_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # Finally, the instance of S3Output is initialized and then invoked
    d.run
  end

  def setup_mocks
    s3bucket = flexmock(AWS::S3::Bucket)
    s3bucket.should_receive(:exists?).with_any_args.and_return { false }
    s3bucket_col = flexmock(AWS::S3::BucketCollection)
    s3bucket_col.should_receive(:[]).with_any_args.and_return { s3bucket }
    flexmock(AWS::S3).new_instances do |bucket|
      bucket.should_receive(:buckets).with_any_args.and_return { s3bucket_col }
    end

    return s3bucket, s3bucket_col
  end

  def test_auto_create_bucket_false_with_non_existence_bucket
    s3bucket, s3bucket_col = setup_mocks

    d = create_time_sliced_driver('auto_create_bucket false')
    assert_raise(RuntimeError, "The specified bucket does not exist: bucket = test_bucket") { 
      d.run
    }
  end

  def test_auto_create_bucket_true_with_non_existence_bucket
    s3bucket, s3bucket_col = setup_mocks
    s3bucket_col.should_receive(:create).with_any_args.and_return { true }

    d = create_time_sliced_driver('auto_create_bucket true')
    assert_nothing_raised { 
      d.run
    }
  end
end
