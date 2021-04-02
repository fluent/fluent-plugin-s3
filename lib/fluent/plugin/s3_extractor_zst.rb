module Fluent::Plugin
  class S3Input
    class ZSTExtractor < Extractor
      S3Input.register_extractor('zst', self)

      config_param :command_parameter, :string, default: '-qq -d -f'

      def configure(conf)
        super
        check_command('zstd')
      end

      def ext
        'zst'.freeze
      end

      def content_type
        'application/x-zst'.freeze
      end

      def extract(io)
        path = if io.respond_to?(path)
                 io.path
               else
                 temp = Tempfile.new("zst-temp")
                 temp.write(io.read)
                 temp.close
                 temp.path
               end

        stdout, succeeded = Open3.capture2("zstd #{@command_parameter} #{path}")
        if succeeded
          stdout
        else
          raise "Failed to extract #{path} with zstd command."
        end
      end
    end
  end
end
