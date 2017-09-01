module Fluent::Plugin
  class S3Output
    class ZSTCompressor < Compressor
      S3Output.register_compressor('zst', self)

      config_param :command_parameter, :string, default: '-qq -f -7'

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

      def compress(chunk, tmp)
        w = Tempfile.new("chunk-tmp")
        w.binmode
        chunk.write_to(w)
        w.close

        # We don't check the return code because we can't recover zstd failure.
        system "zstd #{@command_parameter} -o #{tmp.path} #{w.path}"
      ensure
        w.close rescue nil
        w.unlink rescue nil
      end
    end
  end
end
