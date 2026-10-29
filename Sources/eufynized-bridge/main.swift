import Foundation
import EufyKit

// The Home Assistant add-on's server: talks to the HomeBase directly over P2P (the same EufyKit as the Mac
// app), serves the Security Camera page through ingress, and feeds live video to go2rtc only while
// someone is watching.
//
// Environment: EUFYNIZED_DATA_DIR (bridge.json, prefs, snapshots; default /data/eufynized), EUFYNIZED_WWW
// (the page; default /app/www), EUFYNIZED_PORT (default 8099), GO2RTC_BIN, FFMPEG_BIN, and
// EUFYNIZED_ALLOW_ALL=1 to accept connections from anywhere (testing; normally only ingress and go2rtc), or
// EUFYNIZED_ALLOW_FROM=192.168.1. (comma-separated address prefixes) for the Mac app on the home network.

extension Bridge {
    static let version = "1.7.2"
}

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let dataDir = URL(fileURLWithPath: env["EUFYNIZED_DATA_DIR"] ?? "/data/eufynized", isDirectory: true)
let wwwDir = URL(fileURLWithPath: env["EUFYNIZED_WWW"] ?? "/app/www", isDirectory: true)
let port = UInt16(env["EUFYNIZED_PORT"] ?? "") ?? 8099
try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

let configFile = dataDir.appendingPathComponent("bridge.json")
let prefixes = (env["EUFYNIZED_ALLOW_FROM"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
// Home Assistant's ingress proxy is 172.30.32.2; go2rtc reads streams from this container (127.0.0.1).
let allowed: Set<String>? = env["EUFYNIZED_ALLOW_ALL"] == "1" ? nil : ["172.30.32.2", "127.0.0.1"]
guard let configData = try? Data(contentsOf: configFile),
      let config = try? JSONDecoder().decode(BridgeConfig.self, from: configData) else {
    // First run: serve the page's sign-in screen until the key is fetched, then start over.
    log("No \(configFile.path) yet: open the Security Camera page (port \(port)) and sign in with your eufy account.")
    let setup = SetupFlow(dataDir: dataDir, configured: false)
    let routes = SetupRoutes(wwwDir: wwwDir, setup: setup)
    let server = HTTPServer(port: port, allowedPeers: allowed, allowedPrefixes: prefixes) { request, connection in routes.handle(request, connection) }
    do { try server.run() } catch { log("Server failed: \(error)"); exit(1) }
}
let optionsFile = URL(fileURLWithPath: env["EUFYNIZED_OPTIONS"] ?? "/data/options.json")
let options = (try? Data(contentsOf: optionsFile)).flatMap { try? JSONDecoder().decode(AddonOptions.self, from: $0) }
    ?? AddonOptions()

let bridge = Bridge(config: config, options: options, dataDir: dataDir, wwwDir: wwwDir, port: port)
log("Eufynized bridge \(Bridge.version): HomeBase \(bridge.homeBaseIP), \(config.cameras.count) cameras, port \(port)")

let alerts = AlertCenter(bridge: bridge)
alerts.start()
let monitors = Monitors(bridge: bridge, alerts: alerts)
alerts.monitors = monitors
bridge.onSettingsRead = { monitors.noteSettings($0, $1) }
bridge.onAlive = { monitors.noteAlive($0) }
monitors.start()
bridge.superviseGo2RTC(binary: env["GO2RTC_BIN"] ?? "/usr/local/bin/go2rtc")

// Close settings sessions nobody has used for a minute, and restart streams that stopped sending video.
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 15)
        bridge.closeIdleControlSessions()
        bridge.hub.restartStuckFeeds()
    }
}

let routes = Routes(bridge: bridge, alerts: alerts, setup: SetupFlow(dataDir: dataDir, configured: true))
if !prefixes.isEmpty { log("Also accepting connections from \(prefixes.joined(separator: ", "))*") }
let server = HTTPServer(port: port, allowedPeers: allowed, allowedPrefixes: prefixes) { request, connection in routes.handle(request, connection) }
do { try server.run() } catch { log("Server failed: \(error)"); exit(1) }
