/// Shared core for Aegis. It holds the data contract (`Event`, `Brief`; v0.1, #58). Stage 1 adds the parsers,
/// the brief pipeline and the XPC message types. Linux-buildable: no Apple-only frameworks (ADR-0004).
public enum AegisKit {
    /// Semantic version of the core package.
    public static let version = "0.0.1"
}
