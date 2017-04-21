module Fluent
  class S3Input
    class LZOExtractor < Extractor
      S3Input.register_extractor('lzo', self)

      config_param :command_parameter, :string, :default => '-qdc'
      config_param :customer_tmp_dir, :string, :default => Dir.tmpdir

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
        path = if io.respond_to?(path)
                 io.path
               else
                 temp = Tempfile.new("lzop-temp")
                 temp.write(io.read)
                 temp.close
                 temp.path
               end

        stdout, succeeded = Open3.capture2("lzop #{@command_parameter} #{path}")
        if succeeded
          stdout
        else
          raise "Failed to extract #{path} with lzop command."
        end
      end
    end
  end
end
