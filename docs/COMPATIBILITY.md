# Compatibility strategy

Barline supports macOS 26 and macOS 27 on Apple Silicon. The OS boundary selects
the backend, and each backend then fails closed when its required capability or
behavioral proof is unavailable.

- `TahoeMenuBarBackend` is the macOS 26 implementation.
- The main-process Golden Gate provider is the macOS 27 implementation. It uses
  public Accessibility inventory and targeted transactions against the system's
  authoritative menu-bar position table. It journals, verifies, and
  conditionally rolls back its own proposals. Unknown or ambiguous identities
  remain unchanged.
- `FallbackMenuBarBackend` exposes no unsupported mutation capability. The app
  must keep settings, profiles, search metadata, diagnostics, import/export,
  System Settings handoff, and reset/recovery accessible in this state.

A capability is unavailable when a symbol is missing, a behavioral probe
fails, or an operation produces a typed compatibility error. A transient empty
or implausibly collapsed snapshot never replaces last-known-good state.

The production build lane is Xcode 26.6 / Swift 6.3 on macOS 26. macOS 27
runtime compatibility is separately exercised on an Apple Silicon macOS 27.0
host; evidence from either lane does not substitute for the other.
