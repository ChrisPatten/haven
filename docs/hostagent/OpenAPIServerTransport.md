# OpenAPI Server Transport Bridge

## Overview

The OpenAPIServerTransport provides a bridge between the OpenAPI runtime (using `HTTPTypes`) and Haven's existing NIO-based HTTP server infrastructure (using `HavenCore.HTTPRequest`/`HTTPResponse`). This allows OpenAPI-generated handlers to coexist with legacy manual routes during the transition to a fully OpenAPI-based API.

## Architecture

### Components

1. **OpenAPIServerTransport** (`Sources/HostHTTP/OpenAPIServerTransport.swift`)
   - Implements the `ServerTransport` protocol from swift-openapi-runtime
   - Stores registered OpenAPI operation handlers
   - Converts between Haven's HTTP types and HTTPTypes
   - Handles path parameter extraction and matching

2. **OpenAPIRouteHandler** (`Sources/HostHTTP/OpenAPIRouteHandler.swift`)
   - Implements the `RouteHandler` protocol
   - Wraps the `OpenAPIServerTransport` for integration with Haven's Router
   - Enables coexistence of OpenAPI and legacy routes

### Type Conversions

The bridge performs bidirectional conversions:

**Request Flow:**
```
HavenCore.HTTPRequest → HTTPTypes.HTTPRequest → OpenAPI Handler → HTTPTypes.HTTPResponse → HavenCore.HTTPResponse
```

**Key Conversions:**
- HTTP method strings → `HTTPTypes.HTTPRequest.Method`
- Header dictionaries → `HTTPTypes.HTTPField` collections
- Body Data → `OpenAPIRuntime.HTTPBody` streams
- Path parameters → `ServerRequestMetadata` with substring values

## Usage

### Integration with Router

To use the OpenAPI transport in the router (see haven-141):

```swift
// Create the transport
let transport = OpenAPIServerTransport()

// Create an API handler and register it with the transport
let apiHandler = APIHandler(config: config)
try apiHandler.registerHandlers(on: transport)

// Wrap the transport in a RouteHandler
let openAPIHandler = OpenAPIRouteHandler(transport: transport)

// Add to router handlers (should be added before catch-all patterns)
let handlers: [RouteHandler] = [
    openAPIHandler,  // OpenAPI routes
    // ... other legacy routes
]
```

### Path Matching

The transport supports OpenAPI path parameters using curly brace syntax:
- Pattern: `/v1/collectors/{collector}:run`
- Matches: `/v1/collectors/imessage:run`, `/v1/collectors/email_imap:run`
- Extracts: `{"collector": "imessage"}` as path parameters

## Implementation Details

### Error Handling

- Invalid requests return 404 with appropriate error messages
- Handler errors are caught and returned as 500 with error details
- Body size is limited to 10MB to prevent memory exhaustion

### Thread Safety

- All handler functions are marked `@Sendable`
- Request/response conversions use `async throws` for proper error propagation
- The transport can safely be shared across multiple concurrent requests

## Future Enhancements

1. Query parameter validation and parsing
2. Middleware support for authentication, logging, etc.
3. Metrics collection for OpenAPI operations
4. Content negotiation based on Accept headers
5. Streaming response support for large payloads

## Related Tasks

- haven-141: Update HTTPServer to register OpenAPI handlers
- haven-142: Remove manual collector routing from buildRouter
- haven-143: Update handler response format (DONE)
- haven-144: Update EmailImapHandler input types (DONE)
- haven-145: Remove legacy JSON parsing code

## References

- [swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime)
- [swift-http-types](https://github.com/apple/swift-http-types)
- OpenAPI Spec: `hostagent/Sources/HostHTTP/API/openapi.yaml`
