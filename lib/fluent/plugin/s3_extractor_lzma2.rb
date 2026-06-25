module Fluent::Plugin
  class S3Input
    class LZMA2Extractor < Extractor
      S3Input.register_extractor('lzma2', self)

      config_param :command_parameter, :string, default: '-qdc'

      def configure(conf)
        super
        check_command('xz', 'LZMA')
      end

      def ext
        'xz'.freeze
      end

      def content_type
        'application/x-xz'.freeze
      end

      def extract(io)
        begin
          extract_with_command("xz #{@command_parameter}", io, "xz-temp")
        rescue SizeLimitError
          raise
        rescue
          raise "Failed to extract #{path} with xz command."
        end
      end
    end
  end
end
