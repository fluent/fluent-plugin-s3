module Fluent::Plugin
  class S3Input
    class LZOExtractor < Extractor
      S3Input.register_extractor('lzo', self)

      config_param :command_parameter, :string, default: '-qdc'

      def configure(conf)
        super
        check_command('lzop', 'LZO')
      end

      def ext
        'lzo'.freeze
      end

      def content_type
        'application/x-lzop'.freeze
      end

      def extract(io)
        begin
          extract_with_command("lzop #{@command_parameter}", io, "lzop-temp")
        rescue SizeLimitError
          raise
        rescue
          raise "Failed to extract #{path} with lzop command."
        end
      end
    end
  end
end
