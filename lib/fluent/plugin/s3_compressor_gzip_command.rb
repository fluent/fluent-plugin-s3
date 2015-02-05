module Fluent
  class S3Output
    class GzipCommandCompressor < Compressor
      S3Output.register_compressor('gzip_command', self)

      config_param :command_parameter, :string, :default => ''

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

      def compress(chunk, tmp)
        chunk_is_file = @buffer_type == 'file'
        path = if chunk_is_file
                 chunk.path
               else
                 w = Tempfile.new("chunk-gzip-tmp")
                 chunk.write_to(w)
                 w.close
                 tmp.close
                 w.path
               end
        # We don't check the return code because we can't recover gzip failure.
        system "gzip #{@command_parameter} -c #{path} > #{tmp.path}"
      ensure
        unless chunk_is_file
          w.close rescue nil
          w.unlink rescue nil
        end
      end
    end
  end
end
