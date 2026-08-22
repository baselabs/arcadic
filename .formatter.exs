# Used by `mix format`.
# The vendored protobuf module under lib/arcadic/transport/grpc/proto/ is generated
# code — excluded so `mix format --check-formatted` never demands a reformat of
# regenerated output.
[
  inputs:
    ["{mix,.formatter}.exs", "{config,test}/**/*.{ex,exs}"] ++
      (Path.wildcard("lib/**/*.{ex,exs}") -- Path.wildcard("lib/arcadic/transport/grpc/proto/*"))
]
