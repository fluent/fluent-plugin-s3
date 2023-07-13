# Configuration: credentials

Both S3 input/output plugin provide several credential methods for authentication/authorization.

## AWS key and secret authentication

These parameters are required when your agent is not running on EC2 instance with an IAM Role. When using an IAM role, make sure to configure `instance_profile_credentials`. Usage can be found below.

### aws_key_id

AWS access key id.

### aws_sec_key

AWS secret key.

## \<assume_role_credentials\> section

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

### role_arn (required)

The Amazon Resource Name (ARN) of the role to assume.

### role_session_name (required)

An identifier for the assumed role session.

### policy

An IAM policy in JSON format.

### duration_seconds

The duration, in seconds, of the role session. The value can range from
900 seconds (15 minutes) to 3600 seconds (1 hour). By default, the value
is set to 3600 seconds.

### external_id

A unique identifier that is used by third parties when assuming roles in
their customers' accounts.

## \<web_identity_credentials\> section

Similar to the assume_role_credentials, but for usage in EKS.

    <match *>
      @type s3

      <web_identity_credentials>
        role_arn          ROLE_ARN
        role_session_name ROLE_SESSION_NAME
        web_identity_token_file AWS_WEB_IDENTITY_TOKEN_FILE
      </web_identity_credentials>
    </match>

See also:

*   [Using IAM Roles - AWS Identity and Access
    Management](http://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use.html)
*   [IAM Roles For Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts-technical-overview.html)
*   [Aws::STS::Client](http://docs.aws.amazon.com/sdkforruby/api/Aws/STS/Client.html)
*   [Aws::AssumeRoleWebIdentityCredentials](https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/AssumeRoleWebIdentityCredentials.html)

### role_arn (required)

The Amazon Resource Name (ARN) of the role to assume.

### role_session_name (required)

An identifier for the assumed role session.

### web_identity_token_file (required)

The absolute path to the file on disk containing the OIDC token

### policy

An IAM policy in JSON format.

### duration_seconds

The duration, in seconds, of the role session. The value can range from
900 seconds (15 minutes) to 43200 seconds (12 hours). By default, the value
is set to 3600 seconds.


## \<instance_profile_credentials\> section

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

### retries

Number of times to retry when retrieving credentials. Default is nil.

### ip_address

Default is 169.254.169.254.

### port

Default is 80.

### http_open_timeout

Default is 5.

### http_read_timeout

Default is 5.

## \<shared_credentials\> section

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

### path

Path to the shared file. Defaults to "#{Dir.home}/.aws/credentials".

### profile_name

Defaults to 'default' or `[ENV]('AWS_PROFILE')`.
