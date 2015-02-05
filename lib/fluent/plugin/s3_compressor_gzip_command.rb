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
                 w.path
               end

        res = system "gzip #{@command_parameter} -c #{path} > #{tmp.path}"
        unless res
          log.warn "failed to execute gzip command. Fallback to GzipWriter. status = #{$?}"
          begin
            tmp.truncate(0)
            gw = Zlib::GzipWriter.new(tmp)
            chunk.write_to(gw)
            gw.close
          ensure
            gw.close rescue nil
          end
        end
      ensure
        unless chunk_is_file
          w.close(true) rescue nil
        end
      end
    end
  end
end
