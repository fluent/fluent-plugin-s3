#!/usr/local/bin/ruby

require 'aws-sdk'
require 'json'
require 'yaml'

module AfterWriteHooks
  class SQS
    def self.run(config_file_path, s3_bucket, s3_path)
      self.config(config_file_path)['queues'].each do |queue_config|
        sqs = AWS::SQS.new(
          access_key_id: queue_config['access_key_id'],
          secret_access_key: queue_config['secret_access_key'],
          region: queue_config['region']
        )
        message = {s3_bucket: s3_bucket, s3_path: s3_path}
        queue = sqs.queues.named(queue_config['name'])
        queue.send_message(message.to_json)
      end
    end

    def self.config(config_file_path)
      @config ||= YAML.load_file(config_file_path)
    end
  end
end

if ARGV.length > 1
  AfterWriteHooks::SQS.run(*ARGV)
end