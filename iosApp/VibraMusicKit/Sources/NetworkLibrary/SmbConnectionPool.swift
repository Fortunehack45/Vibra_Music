import Foundation

// Ports data/smb/SmbConnection.kt: the one open session to the configured
// server. All share access funnels through `session()`, which reconnects
// when the wire died mid-flight — but only transport failures retry. A
// status answer from the server (bad password, no such share) is final and
// fails fast instead of authenticating twice against a lockout counter.
//
// Unlike Android's global object, the pool is a value the app holds (one per
// credentials set), so tests can run side by side and a credential change
// drops the old session by replacing the pool.

/// The pooled SMB session for one credentials set.
public actor SmbConnectionPool {
    private let factory: any SmbSessionFactory
    private var credentials: SmbCredentials
    private var live: (credentials: SmbCredentials, session: any SmbShareSession)?

    public init(credentials: SmbCredentials, factory: any SmbSessionFactory) {
        self.credentials = credentials
        self.factory = factory
    }

    /// New credentials (server or password changed): the pooled session is
    /// dropped and never read from again.
    public func update(credentials: SmbCredentials) async {
        if credentials != self.credentials {
            await invalidate()
            self.credentials = credentials
        }
    }

    public func invalidate() async {
        if let live {
            await live.session.close()
            self.live = nil
        }
    }

    /// The connected share, reconnecting once when the previous wire died.
    /// Only `SmbTransportRetry` failures (dropped connections) retry; server
    /// status answers propagate as thrown.
    public func session() async throws -> any SmbShareSession {
        if let live, live.credentials == credentials {
            return live.session
        }
        let wanted = credentials
        let session = try await factory.connect(wanted)
        // While this connect was suspended, `update` may have swapped the settings, or a
        // concurrent caller may have connected already.
        if credentials != wanted {
            await session.close()
            return try await self.session()
        }
        if let live {
            await session.close()
            return live.session
        }
        live = (wanted, session)
        return session
    }

    /// Runs `block` on the pooled session, reconnecting once when the wire
    /// died mid-flight.
    public func withSession<T>(_ block: (any SmbShareSession) async throws -> T) async throws -> T {
        // A failed connect (a wrong password, a missing share) is final: retrying it would
        // authenticate twice.
        let current = try await session()
        do {
            return try await block(current)
        } catch let error as SmbError {
            // Server answers are final.
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await invalidate()
            return try await block(session())
        }
    }
}
