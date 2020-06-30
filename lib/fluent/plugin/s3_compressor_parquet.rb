require "open3"

module Fluent::Plugin
  class S3Output
    class ParquetCompressor < Compressor
      S3Output.register_compressor("parquet", self)

      config_section :compress, multi: false do
        desc "parquet compression codec"
        config_param :parquet_compression_codec, :enum, list: [:uncompressed, :snappy, :gzip, :lzo, :brotli, :lz4, :zstd], default: :snappy
        desc "parquet file page size"
        config_param :parquet_page_size, :size, default: 8192
        desc "parquet file row group size"
        config_param :parquet_row_group_size, :size, default: 128 * 1024 * 1024
        desc "record data format type"
        config_param :record_type, :enum, list: [:avro, :csv, :jsonl, :msgpack, :tsv, :json], default: :msgpack
        desc "schema type"
        config_param :schema_type, :enum, list: [:avro, :bigquery], default: :avro
        desc "path to schema file"
        config_param :schema_file, :string
      end

      def configure(conf)
        super
        check_command("columnify", "-h")

        if [:lzo, :brotli, :lz4].include?@compress.parquet_compression_codec
          raise Fluent::ConfigError, "unsupported compression codec: #{@compress.parquet_compression_codec}"
        end

        @parquet_compression_codec = @compress.parquet_compression_codec.to_s.upcase
        if @compress.record_type == :json
          @record_type = :jsonl
        else
          @record_type = @compress.record_type
        end
      end

      def ext
        "parquet".freeze
      end

      def content_type
        "application/octet-stream".freeze
      end

      def compress(chunk, tmp)
        chunk_is_file = @buffer_type == "file"
        path = if chunk_is_file
                 chunk.path
               else
                 w = Tempfile.new("chunk-parquet-tmp")
                 w.binmode
                 chunk.write_to(w)
                 w.close
                 w.path
               end
        stdout, stderr, status = columnify(path, tmp.path)
        unless status.success?
          raise "failed to execute columnify command. stdout=#{stdout} stderr=#{stderr} status=#{status.inspect}"
        end
      ensure
        unless chunk_is_file
          w.close(true) rescue nil
        end
      end

      private

      def columnify(src_path, dst_path)
        Open3.capture3("columnify",
                       "-parquetCompressionCodec", @parquet_compression_codec,
                       "-parquetPageSize", @compress.parquet_page_size.to_s,
                       "-parquetRowGroupSize", @compress.parquet_row_group_size.to_s,
                       "-recordType", @record_type.to_s,
                       "-schemaType", @compress.schema_type.to_s,
                       "-schemaFile", @compress.schema_file,
                       "-output", dst_path,
                       src_path)
      end
    end
  end
end
