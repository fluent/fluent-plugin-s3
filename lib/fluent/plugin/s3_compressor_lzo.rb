module Fluent
  class S3Output
    class LZOCompressor < Compressor
      S3Output.register_compressor('lzo', self)

      config_param :command_parameter, :string, :default => '-qf1'

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

      def compress(chunk, tmp)
        w = Tempfile.new("chunk-tmp")
        chunk.write_to(w)
        w.close

        # We don't check the return code because we can't recover lzop failure.
        system "lzop #{@command_parameter} -o #{tmp.path} #{w.path}"
      ensure
        w.close rescue nil
        w.unlink rescue nil
      end
    end
  end
end
