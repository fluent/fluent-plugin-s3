module Fluent
  class S3Output
    class Lz4CommandCompressor < Compressor
      S3Output.register_compressor('lz4', self)

      config_param :command_parameter, :string, :default => '-q'

      def configure(conf)
        super
        check_command('lz4')
      end

      def ext
        'lz4'.freeze
      end

      def content_type
        'application/x-lz4'.freeze
      end

      def compress(chunk, tmp)
        chunk_is_file = @buffer_type == 'file'
        path = if chunk_is_file
                 chunk.path
               else
                 w = Tempfile.new("chunk-lz4-tmp")
                 w.binmode
                 chunk.write_to(w)
                 w.close
                 w.path
               end

        # We don't check the return code because we can't recover lz4 failure.
        system "lz4 #{@command_parameter} -c #{path} > #{tmp.path}"
      ensure
        unless chunk_is_file
          w.close(true) rescue nil
        end
      end
    end
  end
end
