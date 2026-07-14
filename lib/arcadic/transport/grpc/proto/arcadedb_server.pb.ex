# GENERATED — do not edit by hand.
# Source: arcadedb-server.proto (ArcadeDB gRPC plugin, package com.arcadedb.grpc),
# regenerate with: protoc --elixir_out=plugins=grpc:OUT -I <dir> arcadedb-server.proto
# (protoc-gen-elixir from the :protobuf escript). Vendored so consumers need no protoc.
#
# Compile-guarded: these modules 'use GRPC.Service'/'use Protobuf' at COMPILE time, but
# both deps are optional — so they are only defined when a consumer opts into the gRPC
# transport by adding :grpc + :protobuf. HTTP/Bolt-only consumers skip this file cleanly.
if Code.ensure_loaded?(Protobuf) and Code.ensure_loaded?(GRPC.Service) do
defmodule Com.Arcadedb.Grpc.TransactionIsolation do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "com.arcadedb.grpc.TransactionIsolation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :READ_UNCOMMITTED, 0
  field :READ_COMMITTED, 1
  field :REPEATABLE_READ, 2
  field :SERIALIZABLE, 3
end

defmodule Com.Arcadedb.Grpc.ProjectionSettings.ProjectionEncoding do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "com.arcadedb.grpc.ProjectionSettings.ProjectionEncoding",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :PROJECTION_AS_LINK, 0
  field :PROJECTION_AS_MAP, 1
  field :PROJECTION_AS_JSON, 2
end

defmodule Com.Arcadedb.Grpc.StreamQueryRequest.RetrievalMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "com.arcadedb.grpc.StreamQueryRequest.RetrievalMode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CURSOR, 0
  field :MATERIALIZE_ALL, 1
  field :PAGED, 2
end

defmodule Com.Arcadedb.Grpc.InsertOptions.ConflictMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "com.arcadedb.grpc.InsertOptions.ConflictMode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CONFLICT_ERROR, 0
  field :CONFLICT_UPDATE, 1
  field :CONFLICT_IGNORE, 2
  field :CONFLICT_ABORT, 3
end

defmodule Com.Arcadedb.Grpc.InsertOptions.TransactionMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "com.arcadedb.grpc.InsertOptions.TransactionMode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :PER_REQUEST, 0
  field :PER_BATCH, 1
  field :PER_STREAM, 2
  field :PER_ROW, 3
  field :NONE, 4
end

defmodule Com.Arcadedb.Grpc.GraphBatchRecord.Kind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "com.arcadedb.grpc.GraphBatchRecord.Kind",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :VERTEX, 0
  field :EDGE, 1
end

defmodule Com.Arcadedb.Grpc.DatabaseCredentials do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.DatabaseCredentials",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :username, 1, type: :string
  field :password, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.TransactionContext do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.TransactionContext",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :transaction_id, 1, type: :string, json_name: "transactionId"
  field :database, 2, type: :string
  field :begin, 3, type: :bool
  field :commit, 4, type: :bool
  field :rollback, 5, type: :bool
  field :timeout_ms, 6, type: :int64, json_name: "timeoutMs"
  field :read_only, 7, type: :bool, json_name: "readOnly"
end

defmodule Com.Arcadedb.Grpc.RowError do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.RowError",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :row_index, 1, type: :uint64, json_name: "rowIndex"
  field :code, 2, type: :string
  field :message, 3, type: :string
  field :field, 4, type: :string
end

defmodule Com.Arcadedb.Grpc.GrpcRecord.PropertiesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcRecord.PropertiesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.GrpcRecord do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcRecord",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :rid, 1, type: :string
  field :type, 2, type: :string

  field :properties, 3,
    repeated: true,
    type: Com.Arcadedb.Grpc.GrpcRecord.PropertiesEntry,
    map: true
end

defmodule Com.Arcadedb.Grpc.GrpcValue do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcValue",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :kind, 0

  field :bool_value, 1, type: :bool, json_name: "boolValue", oneof: 0
  field :int32_value, 2, type: :int32, json_name: "int32Value", oneof: 0
  field :int64_value, 3, type: :int64, json_name: "int64Value", oneof: 0
  field :float_value, 4, type: :float, json_name: "floatValue", oneof: 0
  field :double_value, 5, type: :double, json_name: "doubleValue", oneof: 0
  field :string_value, 6, type: :string, json_name: "stringValue", oneof: 0
  field :bytes_value, 7, type: :bytes, json_name: "bytesValue", oneof: 0

  field :timestamp_value, 8,
    type: Google.Protobuf.Timestamp,
    json_name: "timestampValue",
    oneof: 0

  field :list_value, 9, type: Com.Arcadedb.Grpc.GrpcList, json_name: "listValue", oneof: 0
  field :map_value, 10, type: Com.Arcadedb.Grpc.GrpcMap, json_name: "mapValue", oneof: 0

  field :embedded_value, 11,
    type: Com.Arcadedb.Grpc.GrpcEmbedded,
    json_name: "embeddedValue",
    oneof: 0

  field :link_value, 12, type: Com.Arcadedb.Grpc.GrpcLink, json_name: "linkValue", oneof: 0

  field :decimal_value, 13,
    type: Com.Arcadedb.Grpc.GrpcDecimal,
    json_name: "decimalValue",
    oneof: 0

  field :logical_type, 14, type: :string, json_name: "logicalType"
end

defmodule Com.Arcadedb.Grpc.GrpcList do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcList",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :values, 1, repeated: true, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.GrpcMap.EntriesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcMap.EntriesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.GrpcMap do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcMap",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :entries, 1, repeated: true, type: Com.Arcadedb.Grpc.GrpcMap.EntriesEntry, map: true
end

defmodule Com.Arcadedb.Grpc.GrpcEmbedded.FieldsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcEmbedded.FieldsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.GrpcEmbedded do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcEmbedded",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :type, 1, type: :string
  field :fields, 2, repeated: true, type: Com.Arcadedb.Grpc.GrpcEmbedded.FieldsEntry, map: true
end

defmodule Com.Arcadedb.Grpc.GrpcLink do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcLink",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :rid, 1, type: :string
  field :type, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.GrpcDecimal do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GrpcDecimal",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :unscaled, 1, type: :sint64
  field :scale, 2, type: :int32
end

defmodule Com.Arcadedb.Grpc.ProjectionSettings do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ProjectionSettings",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :include_projections, 1, type: :bool, json_name: "includeProjections"

  field :projection_encoding, 2,
    type: Com.Arcadedb.Grpc.ProjectionSettings.ProjectionEncoding,
    json_name: "projectionEncoding",
    enum: true

  field :soft_limit_bytes, 3,
    proto3_optional: true,
    type: Google.Protobuf.Int32Value,
    json_name: "softLimitBytes"
end

defmodule Com.Arcadedb.Grpc.StreamQueryRequest.ParametersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.StreamQueryRequest.ParametersEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.StreamQueryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.StreamQueryRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :query, 2, type: :string

  field :parameters, 3,
    repeated: true,
    type: Com.Arcadedb.Grpc.StreamQueryRequest.ParametersEntry,
    map: true

  field :credentials, 4, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :batch_size, 5, type: :int32, json_name: "batchSize"

  field :retrieval_mode, 6,
    type: Com.Arcadedb.Grpc.StreamQueryRequest.RetrievalMode,
    json_name: "retrievalMode",
    enum: true

  field :language, 7, type: :string
  field :transaction, 8, type: Com.Arcadedb.Grpc.TransactionContext
  field :projectionSettings, 9, type: Com.Arcadedb.Grpc.ProjectionSettings
end

defmodule Com.Arcadedb.Grpc.QueryResult do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.QueryResult",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :records, 1, repeated: true, type: Com.Arcadedb.Grpc.GrpcRecord
  field :total_records_in_batch, 2, type: :int32, json_name: "totalRecordsInBatch"
  field :running_total_emitted, 3, type: :int64, json_name: "runningTotalEmitted"
  field :is_last_batch, 4, type: :bool, json_name: "isLastBatch"
end

defmodule Com.Arcadedb.Grpc.BeginTransactionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.BeginTransactionRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :isolation, 3, type: Com.Arcadedb.Grpc.TransactionIsolation, enum: true
end

defmodule Com.Arcadedb.Grpc.BeginTransactionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.BeginTransactionResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :transaction_id, 1, type: :string, json_name: "transactionId"
  field :timestamp, 2, type: :int64
end

defmodule Com.Arcadedb.Grpc.CommitTransactionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CommitTransactionRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :transaction, 1, type: Com.Arcadedb.Grpc.TransactionContext
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
end

defmodule Com.Arcadedb.Grpc.CommitTransactionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CommitTransactionResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :committed, 2, type: :bool
  field :message, 3, type: :string
  field :timestamp, 4, type: :int64
end

defmodule Com.Arcadedb.Grpc.RollbackTransactionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.RollbackTransactionRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :transaction, 1, type: Com.Arcadedb.Grpc.TransactionContext
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
end

defmodule Com.Arcadedb.Grpc.RollbackTransactionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.RollbackTransactionResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :rolled_back, 2, type: :bool, json_name: "rolledBack"
  field :message, 3, type: :string
end

defmodule Com.Arcadedb.Grpc.DeleteRecordRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.DeleteRecordRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :rid, 2, type: :string
  field :credentials, 3, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :transaction, 4, type: Com.Arcadedb.Grpc.TransactionContext
end

defmodule Com.Arcadedb.Grpc.DeleteRecordResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.DeleteRecordResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :deleted, 2, type: :bool
  field :message, 3, type: :string
end

defmodule Com.Arcadedb.Grpc.ExecuteCommandRequest.ParametersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExecuteCommandRequest.ParametersEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.ExecuteCommandRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExecuteCommandRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :command, 2, type: :string

  field :parameters, 3,
    repeated: true,
    type: Com.Arcadedb.Grpc.ExecuteCommandRequest.ParametersEntry,
    map: true

  field :credentials, 4, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :transaction, 5, type: Com.Arcadedb.Grpc.TransactionContext
  field :language, 6, type: :string
  field :return_rows, 7, type: :bool, json_name: "returnRows"
  field :max_rows, 8, type: :int32, json_name: "maxRows"
  field :projectionSettings, 9, type: Com.Arcadedb.Grpc.ProjectionSettings
end

defmodule Com.Arcadedb.Grpc.ExecuteCommandResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExecuteCommandResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :message, 2, type: :string
  field :affected_records, 3, type: :int64, json_name: "affectedRecords"
  field :execution_time_ms, 4, type: :int64, json_name: "executionTimeMs"
  field :records, 5, repeated: true, type: Com.Arcadedb.Grpc.GrpcRecord
end

defmodule Com.Arcadedb.Grpc.ExecuteQueryRequest.ParametersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExecuteQueryRequest.ParametersEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.ExecuteQueryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExecuteQueryRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :query, 2, type: :string

  field :parameters, 3,
    repeated: true,
    type: Com.Arcadedb.Grpc.ExecuteQueryRequest.ParametersEntry,
    map: true

  field :credentials, 4, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :transaction, 5, type: Com.Arcadedb.Grpc.TransactionContext
  field :limit, 6, type: :int32
  field :timeout_ms, 7, type: :int32, json_name: "timeoutMs"
  field :projectionSettings, 8, type: Com.Arcadedb.Grpc.ProjectionSettings
  field :language, 9, type: :string
end

defmodule Com.Arcadedb.Grpc.ExecuteQueryResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExecuteQueryResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :results, 1, repeated: true, type: Com.Arcadedb.Grpc.QueryResult
  field :execution_time_ms, 2, type: :int64, json_name: "executionTimeMs"
  field :query_plan, 3, type: :string, json_name: "queryPlan"
end

defmodule Com.Arcadedb.Grpc.CreateRecordRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CreateRecordRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :type, 3, type: :string
  field :record, 4, type: Com.Arcadedb.Grpc.GrpcRecord
  field :transaction, 5, type: Com.Arcadedb.Grpc.TransactionContext
end

defmodule Com.Arcadedb.Grpc.CreateRecordResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CreateRecordResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :rid, 1, type: :string
end

defmodule Com.Arcadedb.Grpc.PropertiesUpdate.PropertiesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.PropertiesUpdate.PropertiesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.PropertiesUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.PropertiesUpdate",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :properties, 1,
    repeated: true,
    type: Com.Arcadedb.Grpc.PropertiesUpdate.PropertiesEntry,
    map: true
end

defmodule Com.Arcadedb.Grpc.UpdateRecordRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.UpdateRecordRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :payload, 0

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :rid, 3, type: :string
  field :record, 4, type: Com.Arcadedb.Grpc.GrpcRecord, oneof: 0
  field :partial, 5, type: Com.Arcadedb.Grpc.PropertiesUpdate, oneof: 0
  field :transaction, 6, type: Com.Arcadedb.Grpc.TransactionContext
end

defmodule Com.Arcadedb.Grpc.UpdateRecordResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.UpdateRecordResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :updated, 2, type: :bool
end

defmodule Com.Arcadedb.Grpc.LookupByRidRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.LookupByRidRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :rid, 3, type: :string
  field :transaction, 4, type: Com.Arcadedb.Grpc.TransactionContext
end

defmodule Com.Arcadedb.Grpc.LookupByRidResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.LookupByRidResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :found, 1, type: :bool
  field :record, 2, type: Com.Arcadedb.Grpc.GrpcRecord
end

defmodule Com.Arcadedb.Grpc.InsertError do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.InsertError",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :message, 1, type: :string
  field :row_index, 2, type: :int64, json_name: "rowIndex"
  field :code, 3, type: :string
  field :field, 4, type: :string
end

defmodule Com.Arcadedb.Grpc.InsertSummary do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.InsertSummary",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :received, 1, type: :int64
  field :inserted, 2, type: :int64
  field :updated, 3, type: :int64
  field :ignored, 4, type: :int64
  field :failed, 5, type: :int64
  field :errors, 6, repeated: true, type: Com.Arcadedb.Grpc.InsertError
  field :execution_time_ms, 7, type: :int64, json_name: "executionTimeMs"
  field :started_at, 8, type: Google.Protobuf.Timestamp, json_name: "startedAt"
  field :finished_at, 9, type: Google.Protobuf.Timestamp, json_name: "finishedAt"
end

defmodule Com.Arcadedb.Grpc.InsertOptions do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.InsertOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :target_class, 1, type: :string, json_name: "targetClass"
  field :key_columns, 2, repeated: true, type: :string, json_name: "keyColumns"

  field :conflict_mode, 3,
    type: Com.Arcadedb.Grpc.InsertOptions.ConflictMode,
    json_name: "conflictMode",
    enum: true

  field :update_columns_on_conflict, 4,
    repeated: true,
    type: :string,
    json_name: "updateColumnsOnConflict"

  field :transaction_mode, 5,
    type: Com.Arcadedb.Grpc.InsertOptions.TransactionMode,
    json_name: "transactionMode",
    enum: true

  field :server_batch_size, 6, type: :int32, json_name: "serverBatchSize"
  field :validate_only, 7, type: :bool, json_name: "validateOnly"
  field :database, 8, type: :string
  field :credentials, 9, type: Com.Arcadedb.Grpc.DatabaseCredentials
end

defmodule Com.Arcadedb.Grpc.BulkInsertRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.BulkInsertRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :options, 3, type: Com.Arcadedb.Grpc.InsertOptions
  field :rows, 4, repeated: true, type: Com.Arcadedb.Grpc.GrpcRecord
  field :transaction, 5, type: Com.Arcadedb.Grpc.TransactionContext
end

defmodule Com.Arcadedb.Grpc.InsertChunk do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.InsertChunk",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :options, 3, type: Com.Arcadedb.Grpc.InsertOptions
  field :transaction, 4, type: Com.Arcadedb.Grpc.TransactionContext
  field :session_id, 5, type: :string, json_name: "sessionId"
  field :chunk_seq, 6, type: :int64, json_name: "chunkSeq"
  field :rows, 7, repeated: true, type: Com.Arcadedb.Grpc.GrpcRecord
  field :last, 8, type: :bool
end

defmodule Com.Arcadedb.Grpc.InsertRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.InsertRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :msg, 0

  field :start, 1, type: Com.Arcadedb.Grpc.Start, oneof: 0
  field :chunk, 2, type: Com.Arcadedb.Grpc.InsertChunk, oneof: 0
  field :commit, 3, type: Com.Arcadedb.Grpc.Commit, oneof: 0
end

defmodule Com.Arcadedb.Grpc.Start do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.Start",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :options, 3, type: Com.Arcadedb.Grpc.InsertOptions
  field :transaction, 4, type: Com.Arcadedb.Grpc.TransactionContext
  field :session_id, 5, type: :string, json_name: "sessionId"
end

defmodule Com.Arcadedb.Grpc.Commit do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.Commit",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :commit, 2, type: :bool
  field :rollback, 3, type: :bool
end

defmodule Com.Arcadedb.Grpc.InsertResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.InsertResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :msg, 0

  field :started, 1, type: Com.Arcadedb.Grpc.Started, oneof: 0
  field :batch_ack, 2, type: Com.Arcadedb.Grpc.BatchAck, json_name: "batchAck", oneof: 0
  field :committed, 3, type: Com.Arcadedb.Grpc.Committed, oneof: 0
  field :error, 4, type: Com.Arcadedb.Grpc.InsertError, oneof: 0
end

defmodule Com.Arcadedb.Grpc.Started do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.Started",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
end

defmodule Com.Arcadedb.Grpc.BatchAck do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.BatchAck",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :chunk_seq, 2, type: :int64, json_name: "chunkSeq"
  field :inserted, 3, type: :int64
  field :updated, 4, type: :int64
  field :ignored, 5, type: :int64
  field :failed, 6, type: :int64
  field :errors, 7, repeated: true, type: Com.Arcadedb.Grpc.InsertError
end

defmodule Com.Arcadedb.Grpc.Committed do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.Committed",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :summary, 1, type: Com.Arcadedb.Grpc.InsertSummary
end

defmodule Com.Arcadedb.Grpc.GraphBatchOptions do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GraphBatchOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :batch_size, 1, type: :int32, json_name: "batchSize"
  field :light_edges, 2, type: :bool, json_name: "lightEdges"
  field :wal, 3, type: :bool
  field :parallel_flush, 4, proto3_optional: true, type: :bool, json_name: "parallelFlush"

  field :pre_allocate_edge_chunks, 5,
    proto3_optional: true,
    type: :bool,
    json_name: "preAllocateEdgeChunks"

  field :edge_list_initial_size, 6, type: :int32, json_name: "edgeListInitialSize"
  field :bidirectional, 7, proto3_optional: true, type: :bool
  field :commit_every, 8, type: :int32, json_name: "commitEvery"
  field :expected_edge_count, 9, type: :int32, json_name: "expectedEdgeCount"
end

defmodule Com.Arcadedb.Grpc.GraphBatchRecord.PropertiesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GraphBatchRecord.PropertiesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Com.Arcadedb.Grpc.GrpcValue
end

defmodule Com.Arcadedb.Grpc.GraphBatchRecord do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GraphBatchRecord",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :kind, 1, type: Com.Arcadedb.Grpc.GraphBatchRecord.Kind, enum: true
  field :type_name, 2, type: :string, json_name: "typeName"
  field :temp_id, 3, type: :string, json_name: "tempId"
  field :from_ref, 4, type: :string, json_name: "fromRef"
  field :to_ref, 5, type: :string, json_name: "toRef"

  field :properties, 6,
    repeated: true,
    type: Com.Arcadedb.Grpc.GraphBatchRecord.PropertiesEntry,
    map: true
end

defmodule Com.Arcadedb.Grpc.GraphBatchChunk do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GraphBatchChunk",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :credentials, 2, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :options, 3, type: Com.Arcadedb.Grpc.GraphBatchOptions
  field :records, 4, repeated: true, type: Com.Arcadedb.Grpc.GraphBatchRecord
end

defmodule Com.Arcadedb.Grpc.GraphBatchResult.IdMappingEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GraphBatchResult.IdMappingEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.GraphBatchResult do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GraphBatchResult",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :vertices_created, 1, type: :int64, json_name: "verticesCreated"
  field :edges_created, 2, type: :int64, json_name: "edgesCreated"
  field :elapsed_ms, 3, type: :int64, json_name: "elapsedMs"

  field :id_mapping, 4,
    repeated: true,
    type: Com.Arcadedb.Grpc.GraphBatchResult.IdMappingEntry,
    json_name: "idMapping",
    map: true
end

defmodule Com.Arcadedb.Grpc.PingRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.PingRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
end

defmodule Com.Arcadedb.Grpc.PingResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.PingResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ok, 1, type: :bool
  field :server_time_ms, 2, type: :int64, json_name: "serverTimeMs"
end

defmodule Com.Arcadedb.Grpc.GetServerInfoRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GetServerInfoRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
end

defmodule Com.Arcadedb.Grpc.GetServerInfoResponse.FeaturesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GetServerInfoResponse.FeaturesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.GetServerInfoResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GetServerInfoResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :version, 1, type: :string
  field :edition, 2, type: :string
  field :start_time_ms, 3, type: :int64, json_name: "startTimeMs"
  field :uptime_ms, 4, type: :int64, json_name: "uptimeMs"
  field :http_port, 5, type: :int32, json_name: "httpPort"
  field :grpc_port, 6, type: :int32, json_name: "grpcPort"
  field :binary_port, 7, type: :int32, json_name: "binaryPort"
  field :databases_count, 8, type: :int32, json_name: "databasesCount"

  field :features, 9,
    repeated: true,
    type: Com.Arcadedb.Grpc.GetServerInfoResponse.FeaturesEntry,
    map: true
end

defmodule Com.Arcadedb.Grpc.ListDatabasesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ListDatabasesRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
end

defmodule Com.Arcadedb.Grpc.ListDatabasesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ListDatabasesResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :databases, 1, repeated: true, type: :string
end

defmodule Com.Arcadedb.Grpc.ExistsDatabaseRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExistsDatabaseRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :name, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.ExistsDatabaseResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.ExistsDatabaseResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :exists, 1, type: :bool
end

defmodule Com.Arcadedb.Grpc.CreateDatabaseRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CreateDatabaseRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :name, 2, type: :string
  field :type, 3, type: :string
end

defmodule Com.Arcadedb.Grpc.CreateDatabaseResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CreateDatabaseResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Com.Arcadedb.Grpc.DropDatabaseRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.DropDatabaseRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :name, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.DropDatabaseResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.DropDatabaseResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Com.Arcadedb.Grpc.GetDatabaseInfoRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GetDatabaseInfoRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :name, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.GetDatabaseInfoResponse.PropertiesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GetDatabaseInfoResponse.PropertiesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.GetDatabaseInfoResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.GetDatabaseInfoResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :type, 2, type: :string
  field :records, 3, type: :int64
  field :classes, 4, type: :int32
  field :indexes, 5, type: :int32
  field :size_bytes, 6, type: :int64, json_name: "sizeBytes"

  field :properties, 7,
    repeated: true,
    type: Com.Arcadedb.Grpc.GetDatabaseInfoResponse.PropertiesEntry,
    map: true
end

defmodule Com.Arcadedb.Grpc.CreateUserRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CreateUserRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :user, 2, type: :string
  field :password, 3, type: :string
  field :role, 4, type: :string
end

defmodule Com.Arcadedb.Grpc.CreateUserResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.CreateUserResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :message, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.DeleteUserRequest do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.DeleteUserRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :credentials, 1, type: Com.Arcadedb.Grpc.DatabaseCredentials
  field :user, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.DeleteUserResponse do
  @moduledoc false

  use Protobuf,
    full_name: "com.arcadedb.grpc.DeleteUserResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :message, 2, type: :string
end

defmodule Com.Arcadedb.Grpc.ArcadeDbService.Service do
  @moduledoc false

  use GRPC.Service, name: "com.arcadedb.grpc.ArcadeDbService", protoc_gen_elixir_version: "0.17.0"

  rpc :StreamQuery, Com.Arcadedb.Grpc.StreamQueryRequest, stream(Com.Arcadedb.Grpc.QueryResult)

  rpc :ExecuteCommand,
      Com.Arcadedb.Grpc.ExecuteCommandRequest,
      Com.Arcadedb.Grpc.ExecuteCommandResponse

  rpc :ExecuteQuery, Com.Arcadedb.Grpc.ExecuteQueryRequest, Com.Arcadedb.Grpc.ExecuteQueryResponse

  rpc :CreateRecord, Com.Arcadedb.Grpc.CreateRecordRequest, Com.Arcadedb.Grpc.CreateRecordResponse

  rpc :UpdateRecord, Com.Arcadedb.Grpc.UpdateRecordRequest, Com.Arcadedb.Grpc.UpdateRecordResponse

  rpc :LookupByRid, Com.Arcadedb.Grpc.LookupByRidRequest, Com.Arcadedb.Grpc.LookupByRidResponse

  rpc :DeleteRecord, Com.Arcadedb.Grpc.DeleteRecordRequest, Com.Arcadedb.Grpc.DeleteRecordResponse

  rpc :BulkInsert, Com.Arcadedb.Grpc.BulkInsertRequest, Com.Arcadedb.Grpc.InsertSummary

  rpc :InsertStream, stream(Com.Arcadedb.Grpc.InsertChunk), Com.Arcadedb.Grpc.InsertSummary

  rpc :InsertBidirectional,
      stream(Com.Arcadedb.Grpc.InsertRequest),
      stream(Com.Arcadedb.Grpc.InsertResponse)

  rpc :BeginTransaction,
      Com.Arcadedb.Grpc.BeginTransactionRequest,
      Com.Arcadedb.Grpc.BeginTransactionResponse

  rpc :CommitTransaction,
      Com.Arcadedb.Grpc.CommitTransactionRequest,
      Com.Arcadedb.Grpc.CommitTransactionResponse

  rpc :RollbackTransaction,
      Com.Arcadedb.Grpc.RollbackTransactionRequest,
      Com.Arcadedb.Grpc.RollbackTransactionResponse

  rpc :GraphBatchLoad,
      stream(Com.Arcadedb.Grpc.GraphBatchChunk),
      Com.Arcadedb.Grpc.GraphBatchResult
end

defmodule Com.Arcadedb.Grpc.ArcadeDbService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Com.Arcadedb.Grpc.ArcadeDbService.Service
end

defmodule Com.Arcadedb.Grpc.ArcadeDbAdminService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "com.arcadedb.grpc.ArcadeDbAdminService",
    protoc_gen_elixir_version: "0.17.0"

  rpc :Ping, Com.Arcadedb.Grpc.PingRequest, Com.Arcadedb.Grpc.PingResponse

  rpc :GetServerInfo,
      Com.Arcadedb.Grpc.GetServerInfoRequest,
      Com.Arcadedb.Grpc.GetServerInfoResponse

  rpc :ListDatabases,
      Com.Arcadedb.Grpc.ListDatabasesRequest,
      Com.Arcadedb.Grpc.ListDatabasesResponse

  rpc :ExistsDatabase,
      Com.Arcadedb.Grpc.ExistsDatabaseRequest,
      Com.Arcadedb.Grpc.ExistsDatabaseResponse

  rpc :CreateDatabase,
      Com.Arcadedb.Grpc.CreateDatabaseRequest,
      Com.Arcadedb.Grpc.CreateDatabaseResponse

  rpc :DropDatabase, Com.Arcadedb.Grpc.DropDatabaseRequest, Com.Arcadedb.Grpc.DropDatabaseResponse

  rpc :GetDatabaseInfo,
      Com.Arcadedb.Grpc.GetDatabaseInfoRequest,
      Com.Arcadedb.Grpc.GetDatabaseInfoResponse

  rpc :CreateUser, Com.Arcadedb.Grpc.CreateUserRequest, Com.Arcadedb.Grpc.CreateUserResponse

  rpc :DeleteUser, Com.Arcadedb.Grpc.DeleteUserRequest, Com.Arcadedb.Grpc.DeleteUserResponse
end

defmodule Com.Arcadedb.Grpc.ArcadeDbAdminService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Com.Arcadedb.Grpc.ArcadeDbAdminService.Service
end
end
