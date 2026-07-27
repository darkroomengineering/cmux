import Foundation

/// Duplicated (not shared) from `tools/mobile-spike`: this is a tiny,
/// spike-scoped error type and the two targets are separate SPM/Xcode build
/// graphs with no shared local package between them. Not worth introducing
/// one for a two-file spike.
struct SpikeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
