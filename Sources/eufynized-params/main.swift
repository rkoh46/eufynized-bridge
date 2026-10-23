import Foundation
import EufyKit

// Diffs two cameras' cloud settings (`params`), to find which setting explains a behaviour difference —
// e.g. which param holds the privacy zone that stops a pan-tilt camera from moving.
//   eufynized-params <email> <camera name A> <camera name B>
//   eufynized-params <email> --dump

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 || args.count == 2 && args[1] == "--dump" else { print("usage: eufynized-params <email> <camera A> <camera B>"); exit(2) }
let client = EufyCloudClient(configuration: .init(email: args[0], countryCode: "US"))
let devices = try await client.devices()
// `--dump`: every camera's params as JSON {name: {deviceType, params}} (for building the settings catalog).
if args[1] == "--dump" {
    let all = devices.filter { !$0.isStation }.reduce(into: [String: Any]()) { out, d in
        out[d.name] = ["deviceType": d.deviceType ?? -1, "params": Dictionary(uniqueKeysWithValues: d.params.map { ("\($0)", $1) })]
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]), as: UTF8.self))
    exit(0)
}
guard let a = devices.first(where: { $0.name == args[1] }), let b = devices.first(where: { $0.name == args[2] }) else {
    print("cameras: \(devices.map(\.name))"); exit(1)
}
print("\(a.name) (\(a.model), \(a.params.count) params) vs \(b.name) (\(b.model), \(b.params.count) params)")
for key in Set(a.params.keys).union(b.params.keys).sorted() where a.params[key] != b.params[key] {
    func show(_ v: String?) -> String { guard let v else { return "—" }; return v.count > 160 && ProcessInfo.processInfo.environment["FULL"] == nil ? String(v.prefix(160)) + "…" : v }
    print("\(key):\n   \(a.name): \(show(a.params[key]))\n   \(b.name): \(show(b.params[key]))")
}
