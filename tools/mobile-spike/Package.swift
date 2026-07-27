// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mobile-spike",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Vendored, verbatim-upstream package. We do not call into its
        // internal wrapper types (CmxIrohLibConnection, path classifiers,
        // etc. are all `internal`, not `public` — see PROVENANCE.md and
        // the M0 spike report). Declared here per the M0 spike brief so the
        // build graph matches Programa's mobile companion dependency, and
        // because it pins the exact iroh-ffi version below.
        .package(path: "../../vendor/CmuxIrohTransport"),
        // Same package + exact version already pulled transitively by
        // CmuxIrohTransport. Declared directly here (not "a new third-party
        // dependency") so this target can `import IrohLib` and drive the
        // raw Iroh endpoint/connection API directly, which is required
        // because we must bypass CmuxIrohTransport's relay-disabled,
        // broker-gated endpoint factory (see M0 spike report).
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            exact: "1.0.2-cmux.3"
        ),
    ],
    targets: [
        .executableTarget(
            name: "iroh-spike",
            dependencies: [
                "CmuxIrohTransport",
                .product(name: "IrohLib", package: "iroh-ffi"),
            ]
        )
    ]
)
