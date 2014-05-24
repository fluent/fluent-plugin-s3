#!/usr/local/bin/ruby

require 'aws-sdk'
require 'json'
require 'yaml'

module AfterWriteHooks
  class SQS
    CONFIG_FILE_PATH = "/path/to/your/config"

    def self.run(s3_bucket, s3_path)
      self.config['queues'].each do |queue_config|
        sqs = AWS::SQS.new(
          access_key_id: queue_config['access_key_id'],
          secret_access_key: queue_config['secret_access_key']
        )
        message = {s3_bucket: s3_bucket, s3_path: s3_path}
        queue = sqs.queues.named(queue_config['name'])
        queue.send_message(message.to_json)
      end
    end

    def self.config
      @config ||= YAML.load_file(CONFIG_FILE_PATH)
    end
  end
end

if ARGV.length > 1
  AfterWriteHooks::SQS.run(*ARGV)
end