# Configuration: Output

Here is a sample configuration and available parameters for fluentd v1 or later.
See also [Configuration: credentials](credentials.md) for common comprehensive parameters.

    <match pattern>
      @type s3

      aws_key_id YOUR_AWS_KEY_ID
      aws_sec_key YOUR_AWS_SECRET_KEY
      s3_bucket YOUR_S3_BUCKET_NAME
      s3_region ap-northeast-1

      path logs/${tag}/%Y/%m/%d/
      s3_object_key_format %{path}%{time_slice}_%{index}.%{file_extension}

      # if you want to use ${tag} or %Y/%m/%d/ like syntax in path / s3_object_key_format,
      # need to specify tag for ${tag} and time for %Y/%m/%d in <buffer> argument.
      <buffer tag,time>
        @type file
        path /var/log/fluent/s3
        timekey 3600 # 1 hour partition
        timekey_wait 10m
        timekey_use_utc true # use utc
      </buffer>
      <format>
        @type json
      </format>
    </match>

For [`<buffer>`](https://docs.fluentd.org/configuration/buffer-section), you can use any record field in `path` / `s3_object_key_format`.

    path logs/${tag}/${foo}
    <buffer tag,foo>
      # parameters...
    </buffer>

See official article for available parameters and usage of placeholder in detail: [Config: Buffer Section](https://docs.fluentd.org/configuration/buffer-section#placeholders)

Note that this configuration doesn't work with fluentd v0.12. See [v0.12](v0.12.md) for v0.12 style.

## aws_iam_retries

This parameter is deprecated. Use [instance_profile_credentials](credentials.md#instance_profile_credentials) instead.

The number of attempts to make (with exponential backoff) when loading
instance profile credentials from the EC2 metadata service using an IAM
role. Defaults to 5 retries.

## s3_bucket (required)

S3 bucket name.

## s3_region

s3 region name. For example, US West (Oregon) Region is "us-west-2". The
full list of regions are available here. >
http://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region. We
recommend using `s3_region` instead of [`s3_endpoint`](#s3_endpoint).

## s3_endpoint

endpoint for S3 compatible services. For example, Riak CS based storage or
something. This option is deprecated for AWS S3, use [`s3_region`](#s3_region) instead.

See also AWS article: [Working with Regions](https://aws.amazon.com/blogs/developer/working-with-regions/).

## enable_transfer_acceleration

Enable [S3 Transfer Acceleration](https://docs.aws.amazon.com/AmazonS3/latest/dev/transfer-acceleration.html) for uploads. **IMPORTANT**: For this to work, you must first enable this feature on your destination S3 bucket.

## enable_dual_stack

Enable [Amazon S3 Dual-Stack Endpoints](https://docs.aws.amazon.com/AmazonS3/latest/dev/dual-stack-endpoints.html) for uploads. Will make it possible to use either IPv4 or IPv6 when connecting to S3.

## use_bundled_cert

For cases where the default SSL certificate is unavailable (e.g. Windows), you can set this option to true in order to use the AWS SDK bundled certificate. Default is false.

This fixes the following error often seen in Windows:

    SSL_connect returned=1 errno=0 state=SSLv3 read server certificate B: certificate verify failed (Seahorse::Client::NetworkingError)

## ssl_ca_bundle

Full path to the SSL certificate authority bundle file that should be used when verifying peer certificates. If you do not pass `ssl_ca_bundle` or `ssl_ca_directory` the the system default will be used if available.

## ssl_ca_directory

Full path of the directory that contains the unbundled SSL certificate authority files for verifying peer certificates. If you do not pass `ssl_ca_bundle` or `ssl_ca_directory` the the system default will be used if available.

## ssl_verify_peer

Verify SSL certificate of the endpoint. Default is true. Set false when you want to ignore the endpoint SSL certificate.

## s3_object_key_format

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
time-slice in text that are formatted with **time_slice_format**.
* %{index} is the sequential number starts from 0, increments when multiple files are uploaded to S3 in the same time slice.
* %{file_extension} depends on **store_as** parameter.
* %{uuid_flush} a uuid that is replaced everytime the buffer will be flushed.
* %{hostname} is replaced with `Socket.gethostname` result.
* %{hex_random} a random hex string that is replaced for each buffer chunk, not
assured to be unique. This is used to follow a way of performance tuning, `Add
a Hex Hash Prefix to Key Name`, written in [Request Rate and Performance
Considerations - Amazon Simple Storage
Service](https://docs.aws.amazon.com/AmazonS3/latest/dev/request-rate-perf-considerations.html).
You can configure the length of string with a
`hex_random_length` parameter (Default: 4).

The default format is `%{path}%{time_slice}_%{index}.%{file_extension}`.
In addition, you can use [buffer placeholders](https://docs.fluentd.org/configuration/buffer-section#placeholders) in this parameter,
so you can embed tag, time and record value like below:

    s3_object_key_format %{path}/events/%Y%m%d/${tag}_%{index}.%{file_extension}
    <buffer tag,time>
      # buffer parameters...
    </buffer>

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

NOTE: ${hostname} placeholder is deprecated since v0.8. You can get same result by using [configuration's embedded ruby code feature](https://docs.fluentd.org/configuration/config-file#embedded-ruby-code).

    s3_object_key_format %{path}%{time_slice}_%{hostname}%{index}.%{file_extension}
    s3_object_key_format "%{path}%{time_slice}_#{Socket.gethostname}%{index}.%{file_extension}"

Above two configurations are same. The important point is wrapping `""` is needed for `#{Socket.gethostname}`.

NOTE: If `check_object` is set to `false`, Ensure the value of `s3_object_key_format` must be unique in each write, If not, existing file will be overwritten.

## force_path_style

:force_path_style (Boolean) — default: false — When set to true, the
bucket name is always left in the request URI and never moved to the host
as a sub-domain. See Plugins::S3BucketDns for more details.

This parameter is deprecated. See AWS announcement: https://aws.amazon.com/blogs/aws/amazon-s3-path-deprecation-plan-the-rest-of-the-story/

## store_as

archive format on S3. You can use several format:

*   gzip (default)
*   json
*   text
*   lzo (Need lzop command)
*   lzma2 (Need xz command)
*   gzip_command (Need gzip command)
    *   This compressor uses an external gzip command, hence would result in
        utilizing CPU cores well compared with `gzip`
*   parquet (Need columnify command)
    *   This compressor uses an external [columnify](https://github.com/reproio/columnify) command.
    *   Use [`<compress>`](#compress-for-parquet-compressor-only) section to configure columnify command behavior.

See [Use your compression algorithm](howto.md#use-your-compression-algorighm) section for adding another format.

## \<compress\> (for parquet compressor only) section

### parquet_compression_codec

parquet compression codec.

* uncompressed
* snappy (default)
* gzip
* lzo (unsupported by columnify)
* brotli (unsupported by columnify)
* lz4 (unsupported by columnify)
* zstd

### parquet_page_size

parquet file page size. default: 8192 bytes

### parquet_row_group_size

parquet file row group size. default: 128 MB

### record_type

record data format type.

* avro
* csv
* jsonl
* msgpack
* tsv
* msgpack (default)
* json

### schema_type

schema type.

* avro (default)
* bigquery

### schema_file (required)

path to schema file.

## \<format\> section

Change one line format in the S3 object. Supported formats are "out_file",
"json", "ltsv", "single_value" and other formatter plugins. See also [official Formatter article](https://docs.fluentd.org/formatter).

* out_file (default).

        time\ttag\t{..json1..}
        time\ttag\t{..json2..}
        ...

* json

        {..json1..}
        {..json2..}
        ...


At this format, "time" and "tag" are omitted. But you can set these
information to the record by setting `<inject>` option. If you set following configuration in
S3 output:

    <format>
      @type json
    </format>
    <inject>
      time_key log_time
    </inject>

then the record has log_time field.

    {"log_time":"time string",...}

See also [official Inject Section article](https://docs.fluentd.org/configuration/inject-section).

* ltsv

        key1:value1\tkey2:value2
        key1:value1\tkey2:value2
        ...

* single_value


Use specified value instead of entire recode. If you get '{"message":"my
log"}', then contents are

    my log1
    my log2
    ...

You can change key name by "message_key" option.

## auto_create_bucket

Create S3 bucket if it does not exists. Default is true.

## check_bucket

Check mentioned bucket if it exists in AWS or not. Default is true.

When it is false, fluentd will not check aws s3 for the existence of the mentioned bucket.
This is the case where bucket will be pre-created before running fluentd.

## check_object

Check object before creation if it exists or not. Default is true.

When it is false, s3_object_key_format will be %{path}%{time_slice}_%{hms_slice}.%{file_extension} by default where,
hms_slice will be time-slice in hhmmss format, so that each object will be unique.
Example object name, assuming it is created on 2016/16/11 3:30:54 PM 20161611_153054.txt (extension can be anything as per user's choice)

## check_apikey_on_start

Check AWS key on start. Default is true.

## proxy_uri

uri of proxy environment.

## path

path prefix of the files on S3. Default is "" (no prefix).
[buffer placeholder](https://docs.fluentd.org/configuration/buffer-section#placeholders) is supported,
so you can embed tag, time and record value like below.

    path logs/%Y%m%d/${tag}/
    <buffer tag,time>
      # buffer parameters...
    </buffer>

## utc

Use UTC instead of local time.

## storage_class

Set storage class. Possible values are `STANDARD`, `REDUCED_REDUNDANCY`, `STANDARD_IA` from [Ruby SDK](http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Object.html#storage_class-instance_method).

Note that reduced redundancy is [not reccomended](https://serverfault.com/a/1010951/512362).

## reduced_redundancy

Use S3 reduced redundancy storage for 33% cheaper pricing. Default is
false.

This is deprecated. Use `storage_class REDUCED_REDUNDANCY` instead.

## acl

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

## grant_full_control

Allows grantee READ, READ_ACP, and WRITE_ACP permissions on the object.
This is useful for cross-account access using IAM roles.

Valid values are `id="Grantee-CanonicalUserID"`. Please specify the grantee's canonical user ID.

e.g. `id="79a59df900b949e55d96a1e698fbacedfd6e09d98eacf8f8d5218e7cd47ef2be"`

Note that a canonical user ID is different from an AWS account ID.
Please refer to [AWS documentation](https://docs.aws.amazon.com/general/latest/gr/acct-identifiers.html) for more details.

## grant_read

Allows grantee to read the object data and its metadata.
Valid values are `id="Grantee-CanonicalUserID"`. Please specify the grantee's canonical user ID.

e.g. `id="79a59df900b949e55d96a1e698fbacedfd6e09d98eacf8f8d5218e7cd47ef2be"`

## grant_read_acp

Allows grantee to read the object ACL.
Valid values are `id="Grantee-CanonicalUserID"`. Please specify the grantee's canonical user ID.

e.g. `id="79a59df900b949e55d96a1e698fbacedfd6e09d98eacf8f8d5218e7cd47ef2be"`

## grant_write_acp

Allows grantee to write the ACL for the applicable object.
Valid values are `id="Grantee-CanonicalUserID"`. Please specify the grantee's canonical user ID.

e.g. `id="79a59df900b949e55d96a1e698fbacedfd6e09d98eacf8f8d5218e7cd47ef2be"`

## hex_random_length

The length of `%{hex_random}` placeholder. Default is 4 as written in
[Request Rate and Performance Considerations - Amazon Simple Storage
Service](https://docs.aws.amazon.com/AmazonS3/latest/dev/request-rate-perf-considerations.html).
The maximum length is 16.

## index_format

`%{index}` is formatted by [sprintf](http://ruby-doc.org/core-2.2.0/Kernel.html#method-i-sprintf) using this format_string. Default is '%d'. Zero padding is supported e.g. `%04d` to ensure minimum length four digits. `%{index}` can be in lowercase or uppercase hex using '%x' or '%X'

## overwrite

Overwrite already existing path. Default is false, which raises an error
if a s3 object of the same path already exists, or increment the
`%{index}` placeholder until finding an absent path.

## use_server_side_encryption

The Server-side encryption algorithm used when storing this object in S3
(e.g., AES256, aws:kms)

## ssekms_key_id

Specifies the AWS KMS key ID to use for object encryption. You have to
set "aws:kms" to [`use_server_side_encryption`](#use_server_side_encryption) to use the KMS encryption.

## sse_customer_algorithm

Specifies the algorithm to use to when encrypting the object (e.g., AES256).

## sse_customer_key

Specifies the AWS KMS key ID to use for object encryption.

## sse_customer_key_md5

Specifies the 128-bit MD5 digest of the encryption key according to RFC 1321.

## checksum_algorithm

AWS allows to calculate the integrity checksum server side. The additional checksum is
used to validate the data during upload or download. The following 4 SHA and CRC algorithms are supported:

* CRC32
* CRC32C
* SHA1
* SHA256

For more info refer to [object integrity](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html).

## compute_checksums

AWS SDK uses MD5 for API request/response by default. On FIPS enabled environment,
OpenSSL returns an error because MD5 is disabled. If you want to use
this plugin on FIPS enabled environment, set `compute_checksums false`.

## signature_version

Signature version for API request. `s3` means signature version 2 and
`v4` means signature version 4. Default is `nil` (Following SDK's default).
It would be useful when you use S3 compatible storage that accepts only signature version 2.

## warn_for_delay

Given a threshold to treat events as delay, output warning logs if delayed events were put into s3.

## tagging

The S3 tag-set for the object. The tag-set must be encoded as URL Query parameters. (For example, "Key1=Value1").

## \<bucket_lifecycle_rule\> section

Specify one or more lifecycle rules for the bucket

    <bucket_lifecycle_rule>
      id UNIQUE_ID_FOR_THE_RULE
      prefix OPTIONAL_PREFIX # Objects whose keys begin with this prefix will be affected by the rule. If not specified all objects of the bucket will be affected
      expiration_days NUMBER_OF_DAYS # The number of days before the object will expire
    </bucket_lifecycle_rule>
