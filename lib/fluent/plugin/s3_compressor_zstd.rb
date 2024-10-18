require 'zstd-ruby'

module Fluent::Plugin
  class S3Output
    class ZstdCompressor < Compressor
      S3Output.register_compressor('zstd', self)

      config_param :level, :integer, default: 3, desc: "Compression level for zstd (1-22)"

      def initialize(opts = {})
        super()
        @buffer_type = opts[:buffer_type]
        @log = opts[:log]
      end

      def ext
        'zst'.freeze
      end

      def content_type
        'application/x-zstd'.freeze
      end

      def compress(chunk, tmp)
        uncompressed_data = ''
        chunk.open do |io|
          uncompressed_data = io.read
        end
        compressed_data = Zstd.compress(uncompressed_data, level: @level)
        tmp.write(compressed_data)
      rescue => e
        log.warn "zstd compression failed: #{e.message}"
        raise e
      end
    end
  end
end
