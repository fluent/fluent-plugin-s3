module Fluent
  class S3Output
    class LZMA2Compressor < Compressor
      S3Output.register_compressor('lzma2', self)

      config_param :command_parameter, :string, :default => '-qf0'

      def configure(conf)
        super
        check_command('xz', 'LZMA2')
      end

      def ext
        'xz'.freeze
      end

      def content_type
        'application/x-xz'.freeze
      end

      def compress(chunk, tmp)
        w = Tempfile.new("chunk-xz-tmp")
        chunk.write_to(w)
        w.close

        # We don't check the return code because we can't recover lzop failure.
        system "xz #{@command_parameter} -c #{w.path} > #{tmp.path}"
      ensure
        w.close rescue nil
        w.unlink rescue nil
      end
    end
  end
end
