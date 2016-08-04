module Fluent
  class S3Input
    class LZMA2Extractor < Extractor
      S3Input.register_extractor('lzma2', self)

      config_param :command_parameter, :string, :default => '-qdc'

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
        path = if io.respond_to?(path)
                 io.path
               else
                 temp = Tempfile.new("xz-temp")
                 temp.write(io.read)
                 temp.close
                 temp.path
               end

        stdout, succeeded = Open3.capture2("xz #{@command_parameter} #{path}")
        if succeeded
          stdout
        else
          raise "Failed to extract #{path} with xz command."
        end
      end
    end
  end
end
