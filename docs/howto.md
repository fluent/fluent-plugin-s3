# Object Metadata Added To Records

If the [`add_object_metadata`](input.md#add_object_metadata) option is set to true, then the name of the bucket
and the key for a given object will be added to each log record as [`s3_bucket`](input.md#s3_bucket)
and [`s3_key`](input.md#s3_key), respectively. This metadata can be used by filter plugins or other
downstream processors to better identify the source of a given record.

# IAM Policy

The following is an example for a IAM policy needed to write to an s3 bucket (matches my-s3bucket/logs, my-s3bucket/test, etc.).

    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "s3:ListBucket"
          ],
          "Resource": "arn:aws:s3:::my-s3bucket"
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:PutObject",
            "s3:GetObject"
          ],
          "Resource": "arn:aws:s3:::my-s3bucket/*"
        }
      ]
    }

Note that the bucket must already exist and **[`auto_create_bucket`](output.md#auto_create_bucket)** has no effect in this case.

`s3:GetObject` is needed for object check to avoid object overwritten.
If you set `check_object false`, `s3:GetObject` is not needed.

Refer to the [AWS
documentation](http://docs.aws.amazon.com/IAM/latest/UserGuide/ExampleIAMPolicies.html) for example policies.

Using [IAM
roles](http://docs.aws.amazon.com/IAM/latest/UserGuide/WorkingWithRoles.html)
with a properly configured IAM policy are preferred over embedding access keys
on EC2 instances.

## Example when `check_bucket false` and `check_object false`

When the mentioned configuration will be made, fluentd will work with the
minimum IAM poilcy, like:


    "Statement": [{
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": ["*"]
    }]


# Use your (de)compression algorithm

s3 plugin has pluggable compression mechanizm like Fluentd's input / output
plugin. If you set 'store_as xxx', `out_s3` plugin searches
`fluent/plugin/s3_compressor_xxx.rb` and `in_s3` plugin searches
`fluent/plugin/s3_extractor_xxx.rb`. You can define your (de)compression with
'S3Output::Compressor'/`S3Input::Extractor` classes. Compressor API is here:

    module Fluent # Since fluent-plugin-s3 v1.0.0 or later, use Fluent::Plugin instead of Fluent
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

`Extractor` is similar to `Compressor`
See bundled `Compressor`/`Extractor` classes for more detail.

