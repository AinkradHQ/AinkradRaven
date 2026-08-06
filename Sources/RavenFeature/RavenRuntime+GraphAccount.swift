import Foundation

/// The Graph half of account setup, kept out of `RavenRuntime.swift` for the same
/// reason `RavenRuntime+IMAPAccount` is: that file is at the repo's line ceiling,
/// so per-backend setup lives beside its backend rather than growing the core.
///
/// There is deliberately no `connect` function here. Graph is an **OAuth** backend,
/// so `RavenRuntime.connectAccount(kind: .graph)` is already the whole flow — the
/// same one Gmail uses, with `ProviderFactory.authorize` picking the right auth by
/// kind. IMAP needed its own entry point because it has a form and credentials to
/// persist; Graph has neither.
@MainActor
extension RavenRuntime {
    /// Whether an Outlook/Graph Connect could possibly succeed — i.e. whether an
    /// Azure app registration (tenant id, client id, client secret) is available.
    ///
    /// Deliberately NOT folded into `canConnectAccount`: that flag asks about the
    /// *Google* OAuth client, and a build can perfectly well have one and not the
    /// other. Sharing the gate would offer Outlook to a Gmail-only build (a button
    /// guaranteed to fail with `notAuthenticated`) and hide it from an Azure-only
    /// one. `ProviderFactory.hasGraphCredentials` is the single source of truth —
    /// the same one `authorize(kind: .graph)` guards on — so the button and the call
    /// cannot disagree.
    public var canConnectGraphAccount: Bool { providerFactory.hasGraphCredentials }
}
