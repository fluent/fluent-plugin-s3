# Input: Setup

1. Create new [SQS](https://aws.amazon.com/documentation/sqs/) queue (use same region as S3)
2. Set proper permission to new queue
3. [Configure S3 event notification](http://docs.aws.amazon.com/AmazonS3/latest/dev/NotificationHowTo.html)
4. Write configuration file such as fluent.conf
5. Run fluentd

# Configuration: Input

See also [Configuration: credentials](credentials.md) for common comprehensive parameters.

    <source>
      @type s3

      aws_key_id YOUR_AWS_KEY_ID
      aws_sec_key YOUR_AWS_SECRET_KEY
      s3_bucket YOUR_S3_BUCKET_NAME
      s3_region ap-northeast-1
      add_object_metadata true
      match_regexp production_.*

      <sqs>
        queue_name YOUR_SQS_QUEUE_NAME
      </sqs>
    </source>

## add_object_metadata

Whether or not object metadata should be added to the record. Defaults to `false`. See below for details.

## match_regexp

If provided, process the S3 object only if its keys matches the regular expression

## s3_bucket (required)

S3 bucket name.

## s3_region

S3 region name. For example, US West (Oregon) Region is
"us-west-2". The full list of regions are available here. >
http://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region. We
recommend using `s3_region` instead of `s3_endpoint`.

## store_as

archive format on S3. You can use serveral format:

* gzip (default)
* json
* text
* lzo (Need lzop command)
* lzma2 (Need xz command)
* gzip_command (Need gzip command)
  * This compressor uses an external gzip command, hence would result in utilizing CPU cores well compared with `gzip`

See [Use your compression algorithm](howto.md#use-your-compression-algorithm) section for adding another format.

## format

Parse a line as this format in the S3 object. Supported formats are
"apache_error", "apache2", "syslog", "json", "tsv", "ltsv", "csv",
"nginx" and "none".

## check_apikey_on_start

Check AWS key on start. Default is true.

## proxy_uri

URI of proxy environment.

## \<sqs\> section

### queue_name (required)

SQS queue name. Need to create SQS queue on the region same as S3 bucket.

### queue_owner_aws_account_id

SQS Owner Account ID

### aws_key_id

Alternative aws key id for SQS

### aws_sec_key

Alternative aws key secret for SQS

### skip_delete

When true, messages are not deleted after polling block. Default is false.

### wait_time_seconds

The long polling interval. Default is 20.

### retry_error_interval

Interval to retry polling SQS if polling unsuccessful, in seconds. Default is 300.
