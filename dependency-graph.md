# Package Dependency Graph

> Render with: `dot -Tpng dependency-graph.dot -o dependency-graph.png`
> Or open `dependency-graph.md` in VS Code with Mermaid preview.

> **Red edges** cross group boundaries.

```mermaid
graph LR
  subgraph sharedinfra["shared-infra"]
    swift_log["swift-log"]
    swift_metrics["swift-metrics"]
    swift_service_context["swift-service-context"]
    swift_atomics["swift-atomics"]
    swift_numerics["swift-numerics"]
    swift_http_types["swift-http-types"]
    swift_http_structured_headers["swift-http-structured-headers"]
    swift_system["swift-system"]
    SwiftProtobuf["SwiftProtobuf"]
    swift_collections["swift-collections"]
    swift_algorithms["swift-algorithms"]
    swift_async_algorithms["swift-async-algorithms"]
    swift_nio["swift-nio"]
    swift_nio_ssl["swift-nio-ssl"]
    swift_nio_http2["swift-nio-http2"]
    swift_nio_extras["swift-nio-extras"]
    swift_nio_transport_services["swift-nio-transport-services"]
    swift_distributed_tracing["swift-distributed-tracing"]
    swift_service_lifecycle["swift-service-lifecycle"]
    async_http_client["async-http-client"]
    grpc_swift["grpc-swift"]
    Opentracing["Opentracing"]
    Thrift["Thrift"]
    opentelemetry_swift["opentelemetry-swift"]
    swift_log_file["swift-log-file"]
  end
  subgraph firebasegroup["firebase"]
    Promises["Promises"]
    InteropForGoogle["InteropForGoogle"]
    GTMSessionFetcher["GTMSessionFetcher"]
    GoogleUtilities["GoogleUtilities"]
    GoogleDataTransport["GoogleDataTransport"]
    AppCheck["AppCheck"]
    Firebase["Firebase"]
  end
  subgraph oktagroup["okta"]
    swift_asn1["swift-asn1"]
    swift_crypto["swift-crypto"]
    swift_certificates["swift-certificates"]
    AuthFoundation["AuthFoundation"]
    OktaIdx["OktaIdx"]
  end
  subgraph pointfreegroup["pointfree"]
    xctest_dynamic_overlay["xctest-dynamic-overlay"]
    swift_concurrency_extras["swift-concurrency-extras"]
    combine_schedulers["combine-schedulers"]
    swift_clocks["swift-clocks"]
  end
  subgraph segmentgroup["segment"]
    Sovran["Sovran"]
    JSONSafeEncoding["JSONSafeEncoding"]
    Segment["Segment"]
  end
  subgraph easywins["easy-wins"]
    GrowthBook_IOS["GrowthBook-IOS"]
    Sentry["Sentry"]
    SimpleKeychain["SimpleKeychain"]
    LRUCache["LRUCache"]
    swiftui_introspect["swiftui-introspect"]
    CombineExt["CombineExt"]
    JSONAny["JSONAny"]
    XCGLogger["XCGLogger"]
    SQLite_swift["SQLite.swift"]
    BitByteData["BitByteData"]
    SWCompression["SWCompression"]
    PriorsSchema["PriorsSchema"]
    CombineExpectations["CombineExpectations"]
  end
  subgraph awsgroup["aws"]
    aws_crt_swift["aws-crt-swift"]
    smithy_swift["smithy-swift"]
    aws_sdk_swift["aws-sdk-swift"]
    AmplifyUtilsNotifications["AmplifyUtilsNotifications"]
    Amplify["Amplify"]
  end

  swift_algorithms --> swift_numerics
  swift_async_algorithms --> swift_collections
  swift_nio --> swift_atomics
  swift_nio --> swift_collections
  swift_nio --> swift_system
  swift_nio_ssl --> swift_nio
  swift_nio_http2 --> swift_nio
  swift_nio_http2 --> swift_atomics
  swift_nio_extras --> swift_nio
  swift_nio_extras --> swift_nio_http2
  swift_nio_extras --> swift_http_types
  swift_nio_extras --> swift_http_structured_headers
  swift_nio_extras --> swift_atomics
  swift_nio_extras --> swift_algorithms
  swift_nio_extras --> swift_certificates
  swift_nio_extras --> swift_nio_ssl
  swift_nio_extras --> swift_asn1
  swift_nio_extras --> swift_service_lifecycle
  swift_nio_extras --> swift_async_algorithms
  swift_nio_extras --> swift_log
  swift_nio_transport_services --> swift_nio
  swift_nio_transport_services --> swift_atomics
  swift_distributed_tracing --> swift_service_context
  swift_service_lifecycle --> swift_log
  swift_service_lifecycle --> swift_async_algorithms
  async_http_client --> swift_nio
  async_http_client --> swift_nio_ssl
  async_http_client --> swift_nio_http2
  async_http_client --> swift_nio_extras
  async_http_client --> swift_nio_transport_services
  async_http_client --> swift_log
  async_http_client --> swift_atomics
  async_http_client --> swift_algorithms
  async_http_client --> swift_distributed_tracing
  grpc_swift --> swift_nio
  grpc_swift --> swift_nio_http2
  grpc_swift --> swift_nio_transport_services
  grpc_swift --> swift_nio_extras
  grpc_swift --> swift_collections
  grpc_swift --> swift_atomics
  grpc_swift --> SwiftProtobuf
  grpc_swift --> swift_log
  grpc_swift --> swift_nio_ssl
  opentelemetry_swift --> swift_nio
  opentelemetry_swift --> grpc_swift
  opentelemetry_swift --> SwiftProtobuf
  opentelemetry_swift --> swift_log
  opentelemetry_swift --> swift_metrics
  opentelemetry_swift --> swift_atomics
  opentelemetry_swift --> Opentracing
  opentelemetry_swift --> Thrift
  swift_log_file --> swift_log
  swift_log_file --> XCGLogger
  GoogleDataTransport --> Promises
  AppCheck --> Promises
  AppCheck --> GoogleUtilities
  Firebase --> Promises
  Firebase --> SwiftProtobuf
  Firebase --> GoogleDataTransport
  Firebase --> GoogleUtilities
  Firebase --> GTMSessionFetcher
  Firebase --> InteropForGoogle
  Firebase --> AppCheck
  swift_crypto --> swift_asn1
  swift_certificates --> swift_crypto
  swift_certificates --> swift_asn1
  OktaIdx --> AuthFoundation
  combine_schedulers --> swift_concurrency_extras
  combine_schedulers --> xctest_dynamic_overlay
  swift_clocks --> swift_concurrency_extras
  swift_clocks --> xctest_dynamic_overlay
  Segment --> Sovran
  Segment --> JSONSafeEncoding
  CombineExt --> combine_schedulers
  SWCompression --> BitByteData
  smithy_swift --> aws_crt_swift
  smithy_swift --> swift_log
  smithy_swift --> opentelemetry_swift
  smithy_swift --> async_http_client
  aws_sdk_swift --> smithy_swift
  aws_sdk_swift --> aws_crt_swift
  Amplify --> aws_sdk_swift
  Amplify --> SQLite_swift
  Amplify --> AmplifyUtilsNotifications
```