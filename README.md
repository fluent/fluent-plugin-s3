# Amazon S3 output plugin for [Fluentd](http://github.com/fluent/fluentd)

[<img src="https://travis-ci.org/fluent/fluent-plugin-s3.svg?branch=master"
alt="Build Status" />](https://travis-ci.org/fluent/fluent-plugin-s3) [<img
src="https://codeclimate.com/github/fluent/fluent-plugin-s3/badges/gpa.svg"
/>](https://codeclimate.com/github/fluent/fluent-plugin-s3)

## Overview

**s3** output plugin buffers event logs in local file and upload it to S3
periodically.

This plugin splits files exactly by using the time of event logs (not the time
when the logs are received). For example, a log '2011-01-02 message B' is
reached, and then another log '2011-01-03 message B' is reached in this order,
the former one is stored in "20110102.gz" file, and latter one in
"20110103.gz" file.

**s3** input plugin reads data from S3 periodically. This plugin uses
SQS queue on the region same as S3 bucket.
We must setup SQS queue and S3 event notification before use this plugin.

## Installation

Simply use RubyGems:

    gem install fluent-plugin-s3

## Output: Configuration

    <match pattern>
      @type s3

      aws_key_id YOUR_AWS_KEY_ID
      aws_sec_key YOUR_AWS_SECRET_KEY
      s3_bucket YOUR_S3_BUCKET_NAME
      s3_region ap-northeast-1
      s3_object_key_format %{path}%{time_slice}_%{index}.%{file_extension}
      path logs/
      buffer_path /var/log/fluent/s3

      time_slice_format %Y%m%d-%H
      time_slice_wait 10m
      utc
    </match>

**aws_key_id**

AWS access key id. This parameter is required when your agent is not
running on EC2 instance with an IAM Role. When using an IAM role, make 
sure to configure `instance_profile_credentials`. Usage can be found below.

**aws_sec_key**

AWS secret key. This parameter is required when your agent is not running
on EC2 instance with an IAM Role.

**aws_iam_retries**

The number of attempts to make (with exponential backoff) when loading
instance profile credentials from the EC2 metadata service using an IAM
role. Defaults to 5 retries.

**s3_bucket (required)**

S3 bucket name.

**s3_region**

s3 region name. For example, US West (Oregon) Region is "us-west-2". The
full list of regions are available here. >
http://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region. We
recommend using `s3_region` instead of `s3_endpoint`.

**s3_endpoint**

endpoint for S3 compatible services. For example, Riak CS based storage or
something. This option doesn't work on S3, use `s3_region` instead.

**ssl_verify_peer**

Verify SSL certificate of the endpoint. Default is true. Set false when you want to ignore the endpoint SSL certificate.

**s3_object_key_format**

The format of S3 object keys. You can use several built-in variables:

*   %{path}
*   %{time_slice}
*   %{index}
*   %{file_extension}
*   %{hex_random}
*   %{uuid_flush}
*   %{hostname}

to decide keys dynamically.

* %{path} is exactly the value of **path** configured in the configuration file.
E.g., "logs/" in the example configuration above.
* %{time_slice} is the
time-slice in text that are formatted with **time_slice_format**. %{index} is
the sequential number starts from 0, increments when multiple files are
uploaded to S3 in the same time slice.
* %{file_extention} is always "gz" for
now.
* %{uuid_flush} a uuid that is replaced everytime the buffer will be flushed. If you want to use this placeholder, install `uuidtools` gem first.
* %{hostname} is replaced with `Socket.gethostname` result. This is same as "#{Socket.gethostname}".
* %{hex_random} a random hex string that is replaced for each buffer chunk, not
assured to be unique. This is used to follow a way of peformance tuning, `Add
a Hex Hash Prefix to Key Name`, written in [Request Rate and Performance
Considerations - Amazon Simple Storage
Service](https://docs.aws.amazon.com/AmazonS3/latest/dev/request-rate-perf-considerations.html).
You can configure the length of string with a
`hex_random_length` parameter (Default: 4).

The default format is `%{path}%{time_slice}_%{index}.%{file_extension}`.

For instance, using the example configuration above, actual object keys on S3
will be something like:

    "logs/20130111-22_0.gz"
    "logs/20130111-23_0.gz"
    "logs/20130111-23_1.gz"
    "logs/20130112-00_0.gz"

With the configuration:

    s3_object_key_format %{path}/events/ts=%{time_slice}/events_%{index}.%{file_extension}
    path log
    time_slice_format %Y%m%d-%H

You get:

    "log/events/ts=20130111-22/events_0.gz"
    "log/events/ts=20130111-23/events_0.gz"
    "log/events/ts=20130111-23/events_1.gz"
    "log/events/ts=20130112-00/events_0.gz"

**force_path_style**

:force_path_style (Boolean) — default: false — When set to true, the
bucket name is always left in the request URI and never moved to the host
as a sub-domain. See Plugins::S3BucketDns for more details.

**store_as**

archive format on S3. You can use serveral format:

*   gzip (default)
*   json
*   text
*   lzo (Need lzop command)
*   lzma2 (Need xz command)
*   gzip_command (Need gzip command)
    *   This compressor uses an external gzip command, hence would result in
        utilizing CPU cores well compared with `gzip`

See `Use your compression algorithm` section for adding another format.

**format**

Change one line format in the S3 object. Supported formats are "out_file",
"json", "ltsv" and "single_value". See also [official Formatter article](http://docs.fluentd.org/articles/formatter-plugin-overview).

* out_file (default).

        time\ttag\t{..json1..}
        time\ttag\t{..json2..}
        ...

* json

        {..json1..}
        {..json2..}
        ...


At this format, "time" and "tag" are omitted. But you can set these
information to the record by setting "include_tag_key" / "tag_key" and
"include_time_key" / "time_key" option. If you set following configuration in
S3 output:

    format json
    include_time_key true
    time_key log_time # default is time

then the record has log_time field.

    {"log_time":"time string",...}

* ltsv

        key1:value1\tkey2:value2
        key1:value1\tkey2:value2
        ...


"ltsv" format also accepts "include_xxx" related options. See "json" section.

* single_value


Use specified value instead of entire recode. If you get '{"message":"my
log"}', then contents are

    my log1
    my log2
    ...

You can change key name by "message_key" option.

**auto_create_bucket**

Create S3 bucket if it does not exists. Default is true.

**check_bukcet**

Check mentioned bucket if it exists in AWS or not. Default is true.

When it is false,
	fluentd will not check aws s3 for the existence of the mentioned bucket. This is the
	case where bucket will be pre-created before running fluentd.

**check_object**

Check object before creation if it exists or not. Default is true.

When it is false,
	s3_object_key_format will be %{path}%{date_slice}_%{time_slice}.%{file_extension}
	where, time_slice will be in hhmmss format, so that each object will be unique.
	Example object name, assuming it is created on 2016/16/11 3:30:54 PM
		20161611_153054.txt (extension can be anything as per user's choice)

**Example when check_bukcet=false and check_object=false**

When the mentioned configuration will be made, fluentd will work with the
minimum IAM poilcy, like:
				"Statement": [{
					"Effect": "Allow",
					"Action": "s3:PutObject",
					"Resource": ["*"]
				}]

**check_apikey_on_start**

Check AWS key on start. Default is true.

**proxy_uri**

uri of proxy environment.

**path**

path prefix of the files on S3. Default is "" (no prefix).

**buffer_path (required)**

path prefix of the files to buffer logs.

**time_slice_format**

Format of the time used as the file name. Default is '%Y%m%d'. Use
'%Y%m%d%H' to split files hourly.

**time_slice_wait**

The time to wait old logs. Default is 10 minutes. Specify larger value if
old logs may reache.

**utc**

Use UTC instead of local time.

**storage_class**

Set storage class. Possible values are `STANDARD`, `REDUCED_REDUNDANCY`, `STANDARD_IA` from [Ruby SDK](http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Object.html#storage_class-instance_method).

**reduced_redundancy**

Use S3 reduced redundancy storage for 33% cheaper pricing. Default is
false.

This is deprecated. Use `storage_class REDUCED_REDUNDANCY` instead.

**acl**

Permission for the object in S3. This is useful for cross-account access
using IAM roles. Valid values are:

*   private (default)
*   public-read
*   public-read-write (not recommended - see [Canned
    ACL](http://docs.aws.amazon.com/AmazonS3/latest/dev/acl-overview.html#canned-acl))
*   authenticated-read
*   bucket-owner-read
*   bucket-owner-full-control

To use cross-account access, you will need to create a bucket policy granting
the specific access required. Refer to the [AWS
documentation](http://docs.aws.amazon.com/AmazonS3/latest/dev/example-walkthroughs-managing-access-example3.html) for examples.

**hex_random_length**

The length of `%{hex_random}` placeholder. Default is 4 as written in
[Request Rate and Performance Considerations - Amazon Simple Storage
Service](https://docs.aws.amazon.com/AmazonS3/latest/dev/request-rate-perf-considerations.html).
The maximum length is 16.

**overwrite**

Overwrite already existing path. Default is false, which raises an error
if a s3 object of the same path already exists, or increment the
`%{index}` placeholder until finding an absent path.

**use_server_side_encryption**

The Server-side encryption algorithm used when storing this object in S3
(e.g., AES256, aws:kms)

**ssekms_key_id**

Specifies the AWS KMS key ID to use for object encryption. You have to
set "aws:kms" to `use_server_side_encryption` to use the KMS encryption.

**sse_customer_algorithm**

Specifies the algorithm to use to when encrypting the object (e.g., AES256).

**sse_customer_key**

Specifies the AWS KMS key ID to use for object encryption.

**sse_customer_key_md5**

Specifies the 128-bit MD5 digest of the encryption key according to RFC 1321.

**compute_checksums**

AWS SDK uses MD5 for API request/response by default. On FIPS enabled environment,
OpenSSL returns an error because MD5 is disabled. If you want to use
this plugin on FIPS enabled environment, set `compute_checksums false`.

**signature_version**

Signature version for API request. `s3` means signature version 2 and
`v4` means signature version 4. Default is `nil` (Following SDK's default).
It would be useful when you use S3 compatible storage that accepts only signature version 2.

**warn_for_delay**

Given a threshold to treat events as delay, output warning logs if delayed events were put into s3.

### assume_role_credentials

Typically, you use AssumeRole for cross-account access or federation.

    <match *>
      @type s3

      <assume_role_credentials>
        role_arn          ROLE_ARN
        role_session_name ROLE_SESSION_NAME
      </assume_role_credentials>
    </match>

See also:

*   [Using IAM Roles - AWS Identity and Access
    Management](http://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use.html)
*   [Aws::STS::Client](http://docs.aws.amazon.com/sdkforruby/api/Aws/STS/Client.html)
*   [Aws::AssumeRoleCredentials](http://docs.aws.amazon.com/sdkforruby/api/Aws/AssumeRoleCredentials.html)

**role_arn (required)**

The Amazon Resource Name (ARN) of the role to assume.

**role_session_name (required)**

An identifier for the assumed role session.

**policy**

An IAM policy in JSON format.

**duration_seconds**

The duration, in seconds, of the role session. The value can range from
900 seconds (15 minutes) to 3600 seconds (1 hour). By default, the value
is set to 3600 seconds.

**external_id**

A unique identifier that is used by third parties when assuming roles in
their customers' accounts.

### instance_profile_credentials

Retrieve temporary security credentials via HTTP request. This is useful on
EC2 instance.

    <match *>
      @type s3

      <instance_profile_credentials>
        ip_address IP_ADDRESS
        port       PORT
      </instance_profile_credentials>
    </match>

See also:

*   [Aws::InstanceProfileCredentials](http://docs.aws.amazon.com/sdkforruby/api/Aws/InstanceProfileCredentials.html)
*   [Temporary Security Credentials - AWS Identity and Access
    Management](http://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html)
*   [Instance Metadata and User Data - Amazon Elastic Compute
    Cloud](http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html)

**retries**

Number of times to retry when retrieving credentials. Default is 5.

**ip_address**

Default is 169.254.169.254.

**port**

Default is 80.

**http_open_timeout**

Default is 5.

**http_read_timeout**

Default is 5.

### shared_credentials

This loads AWS access credentials from local ini file. This is useful for
local developing.

    <match *>
      @type s3

      <shared_credentials>
        path         PATH
        profile_name PROFILE_NAME
      </shared_credentials>
    </match>

See also:

*   [Aws::SharedCredentials](http://docs.aws.amazon.com/sdkforruby/api/Aws/SharedCredentials.html)

**path**

Path to the shared file. Defaults to "#{Dir.home}/.aws/credentials".

**profile_name**

Defaults to 'default' or `[ENV]('AWS_PROFILE')`.

## Input: Setup

1. Create new [SQS](https://aws.amazon.com/documentation/sqs/) queue (use same region as S3)
2. Set proper permission to new queue
3. [Configure S3 event notification](http://docs.aws.amazon.com/AmazonS3/latest/dev/NotificationHowTo.html)
4. Write configuration file such as fluent.conf
5. Run fluentd

## Input: Configuration

    <source>
      type s3

      aws_key_id YOUR_AWS_KEY_ID
      aws_sec_key YOUR_AWS_SECRET_KEY
      s3_bucket YOUR_S3_BUCKET_NAME
      s3_region ap-northeast-1

      <sqs>
        queue_name YOUR_SQS_QUEUE_NAME
      </sqs>
    </source>

**aws_key_id**

AWS access key id. This parameter is required when your agent is not running on EC2 instance with an IAM Role.

**aws_sec_key**

AWS secret key. This parameter is required when your agent is not running on EC2 instance with an IAM Role.

**aws_iam_retries**

The number of attempts to make (with exponential backoff) when loading instance profile credentials from the EC2 metadata
service using an IAM role. Defaults to 5 retries.

**s3_bucket (required)**

S3 bucket name.

**s3_region**

S3 region name. For example, US West (Oregon) Region is
"us-west-2". The full list of regions are available here. >
http://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region. We
recommend using `s3_region` instead of `s3_endpoint`.

**store_as**

archive format on S3. You can use serveral format:

* gzip (default)
* json
* text
* lzo (Need lzop command)
* lzma2 (Need xz command)
* gzip_command (Need gzip command)
  * This compressor uses an external gzip command, hence would result in utilizing CPU cores well compared with `gzip`

See 'Use your compression algorithm' section for adding another format.

**format**

Parse a line as this format in the S3 object. Supported formats are
"apache_error", "apache2", "syslog", "json", "tsv", "ltsv", "csv",
"nginx" and "none".

**check_apikey_on_start**

Check AWS key on start. Default is true.

**proxy_uri**

URI of proxy environment.

**sqs/queue_name (required)**

SQS queue name. Need to create SQS queue on the region same as S3 bucket.

**sqs/skip_delete**

When true, messages are not deleted after polling block. Default is false.

**sqs/wait_time_seconds**

The long polling interval. Default is 20.

## IAM Policy

The following is an example for a minimal IAM policy needed to write to an s3
bucket (matches my-s3bucket/logs, my-s3bucket-test, etc.).

    { "Statement": [
     { "Effect":"Allow",
       "Action":"s3:*",
       "Resource":"arn:aws:s3:::my-s3bucket*"
      } ]
    }

Note that the bucket must already exist and **auto_create_bucket** has no
effect in this case.

Refer to the [AWS
documentation](http://docs.aws.amazon.com/IAM/latest/UserGuide/ExampleIAMPolicies.html) for example policies.

Using [IAM
roles](http://docs.aws.amazon.com/IAM/latest/UserGuide/WorkingWithRoles.html)
with a properly configured IAM policy are preferred over embedding access keys
on EC2 instances.

## Use your compression algorithm

s3 plugin has plugabble compression mechanizm like Fleuntd's input / output
plugin. If you set 'store_as xxx', s3 plugin searches
`fluent/plugin/s3_compressor_xxx.rb`. You can define your compression with
'S3Output::Compressor' class. Compressor API is here:

    module Fluent
      class S3Output
        class XXXCompressor < Compressor
          S3Output.register_compressor('xxx', self)

          # Used to file extension
          def ext
            'xxx'
          end

          # Used to file content type
          def content_type
            'application/x-xxx'
          end

          # chunk is buffer chunk. tmp is destination file for upload
          def compress(chunk, tmp)
            # call command or something
          end
        end
      end
    end

See bundled Compressor classes for more detail.

## Website, license, et. al.

| Web site          | http://fluentd.org/                       |
|-------------------|-------------------------------------------|
| Documents         | http://docs.fluentd.org/                  |
| Source repository | http://github.com/fluent/fluent-plugin-s3 |
| Discussion        | http://groups.google.com/group/fluentd    |
| Author            | Sadayuki Furuhashi                        |
| Copyright         | (c) 2011 FURUHASHI Sadayuki               |
| License           | Apache License, Version 2.0               |
