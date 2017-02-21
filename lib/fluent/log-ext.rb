require 'fluent/log'
# For Fluentd v0.14.13 or earlier
# logger for Aws::S3::Client and Aws::SQS::Client required `#<<` method
module Fluent
  class Log
    unless method_defined?(:<<)
      def <<(message)
        write(message)
      end
    end
  end
end
