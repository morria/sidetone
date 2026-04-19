import Testing

/// Parent suite that serializes every test touching real TCP loopback.
///
/// Swift Testing's `.serialized` trait only serializes within its own
/// suite, so two sibling suites both marked `.serialized` can still run
/// concurrently with each other. Network.framework's dispatch queues
/// deadlock under that concurrency on our CI hardware. Nesting every
/// network-touching suite under this single serialized parent fixes it:
/// all the integration tests now run one at a time.
@Suite("Integration", .serialized)
enum IntegrationTests {}
