module Fluent::Plugin
  class S3Input
    class GzipCommandExtractor < Extractor
      S3Input.register_extractor('gzip_command', self)

      config_param :command_parameter, :string, default: '-dc'

      def configure(conf)
        super
        check_command('gzip')
      end

      def ext
        'gz'.freeze
      end

      def content_type
        'application/x-gzip'.freeze
      end

      def extract(io)
        begin
          extract_with_command("gzip #{@command_parameter}", io, "gzip-temp")
        rescue SizeLimitError
          raise
        rescue => e
          log.warn "gzip command execution failed: #{e.message}. Fallback to GzipExtractor."
          io.rewind
          extractor = GzipExtractor.new(log: log, decompression_size_limit: @decompression_size_limit)
          extractor.extract(io)
        end
      end
    end
  end
end
