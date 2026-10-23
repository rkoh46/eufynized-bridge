import Foundation
import EufyKit

// Finds a HomeBase on the local network and prints where it answers from.
//   swift run eufynized-discover [known-LAN-ip]
// With no argument it relies on broadcast only.

let knownAddress = CommandLine.arguments.dropFirst().first

do {
    print("Looking for a HomeBase\(knownAddress.map { " (also trying \($0))" } ?? "")…")
    let result = try await HomeBaseDiscovery.find(knownAddress: knownAddress)
    print("HomeBase answered from \(result.host):\(result.port) in \(String(format: "%.2f", result.elapsed))s")
    print("Announced P2P id: \(result.announcedDID ?? "none in reply")")
} catch {
    print(error.localizedDescription)
    exit(1)
}
