// The v2 build is compiled with PROBE_V2 (scripts/lib.sh), so the machine code
// differs between v1 and v2, not only Info.plist. That changes the CDHash and so
// the ad-hoc designated requirement.
enum ProbeBuild {
    #if PROBE_V2
    static let codeVariant = "v2: rebuilt with a code change"
    static func checksum(_ bytes: [UInt8]) -> Int { bytes.reduce(7) { $0 &* 31 &+ Int($1) } }
    #else
    static let codeVariant = "v1"
    static func checksum(_ bytes: [UInt8]) -> Int { bytes.reduce(0) { $0 &+ Int($1) } }
    #endif
}
