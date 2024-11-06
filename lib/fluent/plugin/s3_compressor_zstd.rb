require 'zstd-ruby'

module Fluent::Plugin
  class S3Output
    class ZstdCompressor < Compressor
      S3Output.register_compressor('zstd', self)

      config_section :compress, param_name: :compress_config, init: true, multi: false do
        desc "Compression level for zstd (1-22)"
        config_param :level, :integer, default: 3
      end

      def ext
        'zst'.freeze
      end

      def content_type
        'application/x-zst'.freeze
      end

      def compress(chunk, tmp)
        w = StringIO.new
        chunk.write_to(w)
        w.rewind
        compressed = Zstd.compress(w.read, level: @compress_config.level)
        tmp.binmode
        tmp.rewind
        tmp.write(compressed)
        tmp.rewind
      rescue => e
        log.warn "zstd compression failed: #{e.message}"
        raise
      end
    end
  end
end