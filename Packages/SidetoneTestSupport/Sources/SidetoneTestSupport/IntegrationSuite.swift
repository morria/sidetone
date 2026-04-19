import Testing

/// Shared parent suite for every test that opens real TCP sockets —
/// any `NWListener`/`NWConnection` work from SidetoneCore, and the
/// NIO server tests in SidetoneServer.
///
/// Swift Testing's `.serialized` trait serializes tests *within* its
/// suite. Sibling serialized suites still run in parallel with each
/// other, which deadlocks Network.framework's dispatch queues when
/// many sockets open concurrently. Nesting every socket-touching
/// suite under this single parent (across test targets!) serializes
/// them all against one another.
@Suite("Integration", .serialized)
public enum IntegrationTests {}
