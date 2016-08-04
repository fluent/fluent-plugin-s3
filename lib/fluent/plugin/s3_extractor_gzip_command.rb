module Fluent
  class S3Input
    class GzipCommandExtractor < Extractor
      S3Input.register_extractor('gzip_command', self)

      config_param :command_parameter, :string, :default => '-dc'

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
        path = if io.respond_to?(:path)
                 io.path
               else
                 temp = Tempfile.new("gzip-temp")
                 temp.write(io.read)
                 temp.close
                 temp.path
               end

        stdout, succeeded = Open3.capture2("gzip #{@command_parameter} #{path}")
        if succeeded
          stdout
        else
          log.warn "failed to execute gzip command. Fallback to GzipReader. status = #{succeeded}"
          begin
            io.rewind
            Zlib::GzipReader.wrap(io) do |gz|
              gz.read
            end
          end
        end
      end
    end
  end
end
