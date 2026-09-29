import libghosttyvt

/// Compiled-in optimization mode reported by libghostty-vt.
public enum VTOptimizeMode: Int32, Sendable {
    case debug = 0
    case releaseSafe = 1
    case releaseSmall = 2
    case releaseFast = 3
}

public enum VTBuildInfoError: Error {
    case queryFailed
}

/// Linkage smoke test for the production GhosttyVT target.
///
/// Queries a constant build-info value through the packaged xcframework.
/// No terminal state is created.
public func ghosttyVTOptimizeMode() throws -> VTOptimizeMode {
    var rawValue: Int32 = -1
    guard ghostty_build_info(GHOSTTY_BUILD_INFO_OPTIMIZE, &rawValue) == GHOSTTY_SUCCESS else {
        throw VTBuildInfoError.queryFailed
    }
    guard let mode = VTOptimizeMode(rawValue: rawValue) else {
        throw VTBuildInfoError.queryFailed
    }
    return mode
}
