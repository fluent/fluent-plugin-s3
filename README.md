# Amazon S3 plugin for [Fluentd](http://github.com/fluent/fluentd)

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

:warning: Be sure to keep a close eye on S3 costs, as a few user have reported [unexpectedly high costs](https://github.com/fluent/fluent-plugin-s3/issues/160).

## Requirements

| fluent-plugin-s3  | fluentd | ruby |
|-------------------|---------|------|
| >= 1.0.0 | >= v0.14.0 | >= 2.1 |
|  < 1.0.0 | >= v0.12.0 | >= 1.9 |

## Installation

Simply use RubyGems:

    # install latest version
    $ gem install fluent-plugin-s3 --no-document # for fluentd v1.0 or later
    # If you need to install specifiv version, use -v option
    $ gem install fluent-plugin-s3 -v 1.3.0 --no-document
    # For v0.12. This is for old v0.12 users. Don't use v0.12 for new deployment
    $ gem install fluent-plugin-s3 -v "~> 0.8" --no-document # for fluentd v0.12


## Configuration: credentials

Both S3 input/output plugin provide several credential methods for authentication/authorization.

See [Configuration: credentials](docs/credentials.md) about details.

## Output Plugin

See [Configuration: Output](docs/output.md) about details.

## Input Plugin

See [Configuration: Input](docs/input.md) about details.

## Tips and How to

* [Object Metadata Added To Records](docs/howto.md#object-metadata-added-to-records)
* [IAM Policy](docs/howto.md#iam-policy)
* [Use your (de)compression algorithm](docs/howto.md#use-your-decompression-algorithm)

## Migration guide

See [Migration guide from v0.12](docs/v0.12.md) about details.

## Website, license, et. al.

| Web site          | http://fluentd.org/                       |
|-------------------|-------------------------------------------|
| Documents         | http://docs.fluentd.org/                  |
| Source repository | http://github.com/fluent/fluent-plugin-s3 |
| Discussion        | http://groups.google.com/group/fluentd    |
| Author            | Sadayuki Furuhashi                        |
| Copyright         | (c) 2011 FURUHASHI Sadayuki               |
| License           | Apache License, Version 2.0               |
