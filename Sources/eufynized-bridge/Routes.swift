import Foundation
import EufyKit

/// The web page's API. Paths are relative to the add-on's ingress root, which Home Assistant strips.
final class Routes {
    let bridge: Bridge
    let alerts: AlertCenter
    private let talkback = TalkbackSessions()

    init(bridge: Bridge, alerts: AlertCenter) {
        self.bridge = bridge
        self.alerts = alerts
    }

    func handle(_ request: HTTPRequest, _ c: HTTPConnection) {
        let path = request.path
        let parts = path.split(separator: "/").map(String.init)
        switch (request.method, parts.first) {
        case (_, "go2rtc"):
            HTTPServer.proxy(request, path: "/" + parts.dropFirst().joined(separator: "/"), to: Bridge.go2rtcPort, over: c)
        case ("GET", "api"), ("POST", "api"), ("PUT", "api"):
            api(request, Array(parts.dropFirst()), c)
        case ("GET", _):
            serveStatic(path, c)
        default:
            c.respondError(404, "Not found")
        }
    }

    private func api(_ request: HTTPRequest, _ parts: [String], _ c: HTTPConnection) {
        switch (request.method, parts.first ?? "", parts.count) {
        case ("GET", "status", _):
            c.respondJSON(["homeBaseIP": bridge.homeBaseIP, "cameras": bridge.config.cameras.count, "alerts": alerts.status,
                           "version": Bridge.version])
        case ("GET", "cameras", 1):
            c.respondJSON(bridge.config.cameras.sorted { $0.channel < $1.channel }.map(cameraJSON))
        case ("GET", "stream", 2):
            guard let channel = UInt8(parts[1].replacingOccurrences(of: ".ts", with: "")) else { return c.respondError(400, "channel") }
            stream(channel, format: .ts, c)
        case ("GET", "live", 2):
            // The page's own player: fragmented MP4 that follows the camera's resolution changes.
            guard let channel = UInt8(parts[1].replacingOccurrences(of: ".mp4", with: "")) else { return c.respondError(400, "channel") }
            if WebSocket.isUpgrade(request) {
            liveSocket(channel, audio: request.query["audio"] == "1", request, c)
        } else {
            stream(channel, format: .fmp4(audio: request.query["audio"] == "1"), c)
        }
        case (_, "cameras", 3...):
            guard let channel = UInt8(parts[1]), bridge.camera(channel) != nil else { return c.respondError(404, "No such camera") }
            camera(request, channel, Array(parts.dropFirst(2)), c)
        case ("GET", "events", 1):
            events(request, c)
        case ("GET", "events", 2) where parts[1] == "image":
            eventImage(request, c)
        case ("GET", "events", 2) where parts[1] == "clip.mp4":
            eventClip(request, c)
        case ("GET", "events", 2) where parts[1] == "clip-progress":
            let path = request.query["path"] ?? ""
            let ready = FileManager.default.fileExists(atPath: cacheFile(path, ext: "mp4").path)
            c.respondJSON(["ready": ready, "bytes": clipLock.withLock { clipProgress[path] } ?? 0])
        case ("GET", "alerts", 1):
            c.respondJSON(["recent": alerts.recentJSON, "settings": alerts.settings, "status": alerts.status])
        case ("GET", "alerts", 2) where parts[1] == "stream":
            alertStream(c, all: request.query["all"] == "1")
        case ("POST", "alerts", 2) where parts[1] == "simulate":
            // {"channel": 2, "eventType": 3102}: a made-up camera event through the real event handling (tests).
            guard let body = request.json(), let channel = (body["channel"] as? NSNumber)?.intValue,
                  let type = (body["eventType"] as? NSNumber)?.intValue, alerts.simulate(channel: channel, eventType: type)
            else { return c.respondError(400, "channel and eventType") }
            c.respondJSON(["ok": true])
        case ("POST", "alerts", 2) where parts[1] == "test":
            alerts.sendTest(); c.respondJSON(["ok": true])
        case ("PUT", "alerts", 2) where parts[1] == "settings":
            guard let body = request.json() else { return c.respondError(400, "JSON body") }
            var update: [String: Any] = [:]
            if let v = body["enabled"] as? Bool { update["alertsEnabled"] = v }
            if let v = body["kinds"] as? [String] { update["alertKinds"] = v }
            if let v = body["mutedChannels"] as? [Int] { update["alertMutedChannels"] = v }
            if let v = body["push"] as? Bool { update["alertPush"] = v }
            if let v = body["notifyService"] as? String { update["notifyService"] = v }   // set by the integration
            if body.keys.contains("quietHours") { update["quietHours"] = (body["quietHours"] as? [String: String]) ?? NSNull() }
            if let v = body["schedules"] as? [String: [String: String]] { update["alertSchedules"] = v }
            if let v = body["digestTime"] as? String { update["digestTime"] = v }
            bridge.prefs.merge(update)
            c.respondJSON(alerts.settings)
        case ("POST", "alerts", 2) where parts[1] == "false-alarm":
            guard let id = request.json()?["id"] as? String else { return c.respondError(400, "id") }
            alerts.markFalseAlarm(id)
            c.respondJSON(["ok": true])
        case ("POST", "alerts", 2) where parts[1] == "digest":
            // Sends the digest now (a test, or on demand).
            alerts.monitors?.sendDigestNow()
            c.respondJSON(["ok": true])
        case ("GET", "guard", 1):
            c.respondJSON(["mode": alerts.guardMode.map { $0 as Any } ?? NSNull()])
        case ("POST", "guard", 1):
            // {"mode": "away" | "home" | "disarmed" | <number>}
            let names = ["away": 0, "home": 1, "schedule": 2, "off": 6, "geo": 47, "disarmed": 63]
            let value = request.json()?["mode"]
            guard let mode = (value as? String).flatMap({ names[$0] }) ?? (value as? NSNumber)?.intValue else {
                return c.respondError(400, "mode: away, home or disarmed")
            }
            guard let code = alerts.setGuardMode(mode) else { return c.respondError(503, "The HomeBase didn't answer") }
            c.respondJSON(["result": code, "mode": alerts.guardMode.map { $0 as Any } ?? NSNull()], status: code == 0 ? 200 : 502)
        case ("GET", "homebase", 1):
            guard let watcher = alerts.eventWatcher, let info = blocking({ await watcher.stationInfo() }) else {
                return c.respondError(503, "The HomeBase didn't answer")
            }
            c.respondJSON(["firmware": info.firmware as Any, "secondaryFirmware": info.secondaryFirmware as Any,
                           "scheduleFallbackMode": info.params[1257].flatMap { Int($0) } as Any,
                           "ip": info.params[1176] as Any, "name": info.params[1216] as Any])
        case ("GET", "storage", 1):
            guard let info = alerts.storageInfo() else { return c.respondError(503, "The HomeBase didn't answer") }
            c.respondJSON(info)
        case ("POST", "probe", 1):
            // {"cmd": 1307, "channel": 0, "payload": {...}} through SET_PAYLOAD, or {"level2": 1271, "json": "…"}:
            // every frame back for `seconds`. Only commands on `probeAllowed` (reads and the snooze being built).
            probe(request, c)
        case ("GET", "experiment", 2) where parts[1] == "ramp":
            // ?ch=2&pre=1&streamtype=1&quality=max&seconds=45: times one stream from start to each resolution.
            guard let channel = UInt8(request.query["ch"] ?? ""), bridge.camera(channel) != nil else { return c.respondError(400, "ch") }
            c.respondJSON(rampExperiment(channel, pre: request.query["pre"] == "1",
                                         streamType: Int(request.query["streamtype"] ?? "") ?? 1,
                                         quality: request.query["quality"].map { StreamQuality(rawValue: $0) } ?? .max,
                                         seconds: Double(request.query["seconds"] ?? "") ?? 45))
        case ("GET", "prefs", 1):
            c.respondJSON(bridge.prefs.all.filter { ["order", "layout", "thumbnailSize", "quality"].contains($0.key) })
        case ("PUT", "prefs", 1):
            guard let body = request.json() else { return c.respondError(400, "JSON body") }
            bridge.prefs.merge(body.filter { ["order", "layout", "thumbnailSize"].contains($0.key) })
            c.respondJSON(["ok": true])
        default:
            c.respondError(404, "Not found")
        }
    }

    private func cameraJSON(_ camera: CameraInfo) -> [String: Any] {
        let channel = UInt8(clamping: camera.channel)
        var json: [String: Any] = [
            "channel": camera.channel, "name": camera.name, "model": camera.model, "serial": camera.serial,
            "ptz": camera.supportsPTZ, "ptzLocked": camera.hasPrivacyZone == true,
            "viewers": bridge.hub.viewers(channel),
            "hasSettings": !CameraSettingsCatalog.settings(forDeviceType: camera.deviceType).isEmpty,
        ]
        if let profile = StreamQualityProfile.forModel(camera.model) ?? StreamQualityProfile.forModel(camera.serial) {
            json["qualities"] = profile.options.map { ["id": $0.rawValue, "label": $0.label] }
            json["quality"] = (bridge.prefs.quality(channel) ?? .max).rawValue
        }
        if let state = bridge.availabilityOf(channel) {
            json["availability"] = availabilityText(state)
            json["online"] = state == .online
        }
        if let date = bridge.snapshotDate(channel) { json["snapshotAt"] = date.timeIntervalSince1970 * 1000 }
        return json
    }

    private func availabilityText(_ state: CameraAvailability) -> String {
        switch state {
        case .online: "online"
        default: "\(state.title)"
        }
    }

    // MARK: Live

    /// A camera's live stream: MPEG-TS for go2rtc, or framed fragmented MP4 for the page. Ends when the reader goes away.
    private func stream(_ channel: UInt8, format: LiveFormat, _ c: HTTPConnection) {
        guard bridge.camera(channel) != nil else { return c.respondError(404, "No such camera") }
        let (feed, subscriber) = bridge.hub.subscribe(channel, format: format)
        defer { bridge.hub.unsubscribe(feed, subscriber) }
        let type = if case .ts = format { "video/mp2t" } else { "application/octet-stream" }
        guard c.beginStream(type: type, headers: ["X-Accel-Buffering": "no"]) else { return }
        var idle: TimeInterval = 0
        while true {
            if let chunk = subscriber.next(timeout: 1) {
                idle = 0
                if !c.write(chunk) { return }
            } else {
                if subscriber.closed { return }
                idle += 1
                if idle > 30 { log("live ch\(channel): no video for 30 s; ending"); return }
                // Nothing to send: notice a closed reader anyway (a zero-byte peek returns 0 on close).
                var probe = pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0)
                if poll(&probe, 1, 0) > 0, c.read(max: 1).isEmpty { return }
            }
        }
    }

    /// The page's player over a WebSocket: one binary message per framed chunk (see `StreamSubscriber.frame`).
    private func liveSocket(_ channel: UInt8, audio: Bool, _ request: HTTPRequest, _ c: HTTPConnection) {
        guard bridge.camera(channel) != nil else { return c.respondError(404, "No such camera") }
        if let state = bridge.knownUnavailable(channel) { return c.respondError(503, state.title) }
        guard WebSocket.accept(request, c) else { return }
        let format: LiveFormat = request.query["format"] == "raw" ? .raw(audio: audio) : .fmp4(audio: audio)
        let (feed, subscriber) = bridge.hub.subscribe(channel, format: format)
        defer { bridge.hub.unsubscribe(feed, subscriber) }
        WebSocket.watchForClose(c) { subscriber.close() }
        while let chunk = subscriber.next(timeout: 45) {
            if !c.write(WebSocket.binaryFrame(chunk)) { return }
        }
    }

    private func camera(_ request: HTTPRequest, _ channel: UInt8, _ rest: [String], _ c: HTTPConnection) {
        switch (request.method, rest.first ?? "") {
        case ("POST", "snooze"):
            // {"minutes": 30}: mute this camera's notifications for a while; 0 ends a snooze.
            guard let minutes = (request.json()?["minutes"] as? NSNumber)?.intValue, (0...1440).contains(minutes)
            else { return c.respondError(400, "minutes 0–1440") }
            let code = alerts.snooze(channel: channel, seconds: minutes * 60)
            if code == 0 || code == nil { alerts.noteSnooze(channel: channel, until: minutes == 0 ? nil : Date().addingTimeInterval(Double(minutes) * 60)) }
            c.respondJSON(["result": code.map { $0 as Any } ?? NSNull(), "snoozedUntil": alerts.snoozedUntil(channel).map { $0.timeIntervalSince1970 as Any } ?? NSNull()])
        case ("GET", "snooze"):
            c.respondJSON(["snoozedUntil": alerts.snoozedUntil(channel).map { $0.timeIntervalSince1970 as Any } ?? NSNull()])
        case ("GET", "snapshot.jpg"):
            let maxAge = request.query["fresh"] != nil ? 0 : (Double(request.query["maxAge"] ?? "") ?? 600)
            // full=1: the camera's full resolution at high JPEG quality (alert pictures); otherwise a 960px thumbnail.
            if request.query["full"] == "1" {
                // settle: seconds to wait for a sharper keyframe (cameras step up resolution as they wake). Alerts use
                // 0, the first fresh frame: a person walking past is gone within seconds.
                let settle = Double(request.query["settle"] ?? "") ?? 6
                guard let jpeg = bridge.fullSnapshot(channel, settle: settle) else { return c.respondError(503, "No picture from the camera") }
                return c.respond(200, jpeg, type: "image/jpeg")
            }
            guard let jpeg = bridge.snapshot(channel, maxAge: maxAge) else {
                return c.respondError(503, bridge.availabilityOf(channel).map(availabilityText) ?? "No picture from the camera")
            }
            c.respond(200, jpeg, type: "image/jpeg")
        case ("POST", "panorama") where rest.count == 1:
            guard bridge.camera(channel)?.supportsPTZ == true else { return c.respondError(400, "This camera doesn't pan") }
            let job = bridge.panorama(channel)
            c.respondJSON(["started": job.start()].merging(job.status) { a, _ in a })
        case ("GET", "panorama"):
            c.respondJSON(bridge.panorama(channel).status)
        case ("GET", "panorama.jpg"):
            guard let jpeg = bridge.panorama(channel).jpeg else { return c.respondError(404, "No panorama yet") }
            c.respond(200, jpeg, type: "image/jpeg")
        case ("POST", "panorama") where rest.count == 2 && rest[1] == "aim":
            // {"x": 0.42}: pan to the step nearest that spot on the panorama.
            guard let x = (request.json()?["x"] as? NSNumber)?.doubleValue, (0...1).contains(x) else { return c.respondError(400, "x 0–1") }
            let job = bridge.panorama(channel)
            guard job.aim(x: x) else { return c.respondError(409, "Make a panorama first") }
            c.respondJSON(job.status)
        case ("POST", "ptz") where rest.count == 2 && rest[1] == "preset":
            // {"action": "go" | "save" | "delete", "index": 0–3}
            guard let body = request.json(), let action = (body["action"] as? String).flatMap(PTZPresetAction.init(rawValue:)),
                  let index = (body["index"] as? NSNumber)?.intValue, (0...3).contains(index) else { return c.respondError(400, "action and index 0–3") }
            guard let camera = bridge.camera(channel), camera.supportsPTZ else { return c.respondError(400, "This camera doesn't pan or tilt") }
            let (stream, fresh) = bridge.controlStream(channel)
            if fresh { Thread.sleep(forTimeInterval: 2.5) }
            stream.preset(action, index: index)
            if action == .save { bridge.prefs.notePreset(channel: channel, index: index, saved: true) }
            if action == .delete { bridge.prefs.notePreset(channel: channel, index: index, saved: false) }
            if action == .go { bridge.scheduleReturnHome(channel, movedTo: index) }
            c.respondJSON(["ok": true, "presets": bridge.prefs.presets(channel)])
        case ("GET", "ptz") where rest.count == 2 && rest[1] == "preset":
            c.respondJSON(["presets": bridge.prefs.presets(channel), "home": bridge.prefs.home(channel) as Any])
        case ("PUT", "ptz") where rest.count == 2 && rest[1] == "home":
            // {"index": 0–3 or null, "minutes": 5}: return to that preset this long after any move.
            guard let body = request.json() else { return c.respondError(400, "JSON body") }
            bridge.prefs.setHome(channel: channel, index: (body["index"] as? NSNumber)?.intValue, minutes: (body["minutes"] as? NSNumber)?.intValue ?? 5)
            c.respondJSON(["home": bridge.prefs.home(channel) as Any])
        case ("POST", "ptz"):
            guard let name = request.json()?["direction"] as? String,
                  let direction = ["left": PTZDirection.left, "right": .right, "up": .up, "down": .down][name]
            else { return c.respondError(400, "direction") }
            guard let camera = bridge.camera(channel), camera.supportsPTZ else { return c.respondError(400, "This camera doesn't pan or tilt") }
            let (stream, fresh) = bridge.controlStream(channel)
            if fresh { Thread.sleep(forTimeInterval: 2.5) }   // let a new session derive its keys
            stream.rotate(direction)
            bridge.scheduleReturnHome(channel, movedTo: nil)
            c.respondJSON(["ok": true])
        case ("POST", "timelapse"):
            // {"date": "2026-10-22", "seconds": 30}: builds a time-lapse of that day from the camera's recordings.
            guard let body = request.json(), let date = body["date"] as? String else { return c.respondError(400, "date") }
            let job = bridge.timelapse(channel, date: date)
            job.start(seconds: (body["seconds"] as? NSNumber)?.doubleValue ?? 30)
            c.respondJSON(job.status)
        case ("GET", "timelapse") where rest.count == 1:
            guard let date = request.query["date"] else { return c.respondError(400, "date") }
            c.respondJSON(bridge.timelapse(channel, date: date).status)
        case ("GET", "timelapse.mp4"):
            guard let date = request.query["date"], let file = bridge.timelapse(channel, date: date).file else { return c.respondError(404, "No time-lapse yet") }
            serveFile(file, type: "video/mp4", request, c)
        case ("GET", "zones"):
            guard let params = bridge.readSettings(channel) else { return c.respondError(503, "The HomeBase didn't answer") }
            let zones = ActivityZones(params: params)
            c.respondJSON(["polygons": (zones?.polygons ?? []).map { $0.map { ["x": $0.x, "y": $0.y] } }, "grid": 1000])
        case ("POST", "zones"):
            // {"polygons": [[{"x":0-1000,"y":0-1000}, …], …]}: replaces the camera's activity zones (none = whole picture).
            guard let body = request.json(), let raw = body["polygons"] as? [[[String: Any]]] else { return c.respondError(400, "polygons") }
            let polygons = raw.map { $0.compactMap { pt -> (x: Int, y: Int)? in
                guard let x = (pt["x"] as? NSNumber)?.intValue, let y = (pt["y"] as? NSNumber)?.intValue else { return nil }
                return (max(0, min(1000, x)), max(0, min(1000, y)))
            } }.filter { $0.count >= 3 }
            guard polygons.count <= 4, let json = ActivityZones(polygons: polygons).controlJSON else { return c.respondError(400, "up to 4 polygons of 3+ points") }
            let (stream, fresh) = bridge.controlStream(channel)
            if fresh { _ = bridge.readSettings(channel) }
            stream.sendControlJSON(json)
            Thread.sleep(forTimeInterval: 1.5)
            let after = bridge.readSettings(channel).flatMap(ActivityZones.init(params:))
            let took = after == ActivityZones(polygons: polygons)
            c.respondJSON(["ok": took, "polygons": (after?.polygons ?? []).map { $0.map { ["x": $0.x, "y": $0.y] } },
                           "message": took ? NSNull() : "The camera didn't take the zones (it reports something else)."])
        case ("GET", "replies"):
            c.respondJSON(["replies": QuickReplies.list(bridge)])
        case ("POST", "replies") where rest.count == 2 && rest[1] == "play":
            guard let name = request.json()?["name"] as? String else { return c.respondError(400, "name") }
            guard let feed = bridge.hub.feed(channel) else { return c.respondError(409, "Open the camera's live view first") }
            guard let file = QuickReplies.file(bridge, name: name) else { return c.respondError(404, "No such reply") }
            talkback.play(file, on: feed.stream, channel: channel)
            c.respondJSON(["ok": true])
        case ("POST", "replies") where rest.count == 2 && rest[1] == "upload":
            // ?name=…: the body is an audio file in any format ffmpeg reads (the page sends 16 kHz PCM; the Mac sends AIFF/WAV).
            guard let name = request.query["name"], !name.isEmpty else { return c.respondError(400, "name") }
            let format = request.query["format"] ?? "auto"
            guard QuickReplies.save(bridge, name: name, audio: request.body, rawPCM: format == "pcm") else { return c.respondError(500, "Couldn't convert the audio") }
            c.respondJSON(["replies": QuickReplies.list(bridge)])
        case ("DELETE", "replies"):
            guard let name = request.query["name"] else { return c.respondError(400, "name") }
            QuickReplies.delete(bridge, name: name)
            c.respondJSON(["replies": QuickReplies.list(bridge)])
        case ("POST", "quality"):
            guard let raw = request.json()?["quality"] as? String, let quality = StreamQuality(rawValue: raw) else {
                return c.respondError(400, "quality")
            }
            bridge.prefs.setQuality(quality, channel: channel)
            bridge.hub.feed(channel)?.stream.setQuality(quality)
            c.respondJSON(["ok": true])
        case ("GET", "settings") where rest.count > 1 && rest[1] == "catalog":
            // The camera model's editable on/off settings, without asking the camera (it may be offline).
            let deviceType = bridge.camera(channel)?.deviceType
            let toggles = CameraSettingsCatalog.settings(forDeviceType: deviceType).compactMap { s -> [String: Any]? in
                guard case .toggle = s.kind, CameraSettingsCatalog.isEditable(s, deviceType: deviceType) else { return nil }
                return ["id": s.id, "label": CameraSettingsCatalog.displayLabel(s)]
            }
            let choices = CameraSettingsCatalog.settings(forDeviceType: deviceType).compactMap { s -> String? in
                guard case .choice = s.kind, CameraSettingsCatalog.isEditable(s, deviceType: deviceType) else { return nil }
                return s.id
            }
            let readings = CameraSettingsCatalog.settings(forDeviceType: deviceType).filter { !$0.writable }.map(\.id)
            c.respondJSON(["toggles": toggles, "choices": choices, "readings": readings])
        case ("GET", "settings") where request.query["raw"] == "1":
            // Every parameter the camera reports, by number (for mapping settings the catalog doesn't know yet).
            guard let params = bridge.readSettings(channel) else { return c.respondError(503, "No answer from the camera") }
            c.respondJSON(Dictionary(uniqueKeysWithValues: params.map { (String($0.key), $0.value) }))
        case ("GET", "settings"):
            settings(channel, c)
        case ("POST", "settings"):
            writeSetting(request, channel, c)
        case ("POST", "talkback"):
            let action = rest.count > 1 ? rest[1] : ""
            talkback.handle(action, channel: channel, body: request.body, bridge: bridge, c)
        default:
            c.respondError(404, "Not found")
        }
    }

    // MARK: Settings

    private func settingsJSON(_ channel: UInt8, _ params: [Int: String]) -> [[String: Any]] {
        let deviceType = bridge.camera(channel)?.deviceType
        let catalog = CameraSettingsCatalog.settings(forDeviceType: deviceType)
        return CameraSettingsCatalog.groupOrder.compactMap { group in
            let rows: [[String: Any]] = catalog.compactMap { setting in
                guard CameraSettingsCatalog.group(of: setting, deviceType: deviceType) == group,
                      let value = CameraSettingsCatalog.value(of: setting, in: params, deviceType: deviceType) else { return nil }
                var row: [String: Any] = ["id": setting.id, "label": CameraSettingsCatalog.displayLabel(setting),
                                          "editable": CameraSettingsCatalog.isEditable(setting, deviceType: deviceType)]
                switch value {
                case .bool(let b): row["value"] = b
                case .int(let i): row["value"] = i
                case .text(let t): row["value"] = t
                }
                switch setting.kind {
                case .toggle: row["kind"] = "toggle"
                case .choice(let options):
                    row["kind"] = "choice"
                    row["options"] = options.map { ["value": $0.value, "label": $0.label] }
                case .number(let min, let max, let step, let unit):
                    row["kind"] = "number"
                    if let min { row["min"] = min }
                    if let max { row["max"] = max }
                    row["step"] = step ?? 1
                    if let unit { row["unit"] = unit }
                    if let values = CameraSettingsCatalog.recipe(for: setting, deviceType: deviceType)?.supportedValues {
                        row["supportedValues"] = values
                    }
                case .text: row["kind"] = "text"
                }
                return row
            }
            return rows.isEmpty ? nil : ["group": group, "settings": rows]
        }
    }

    private func settings(_ channel: UInt8, _ c: HTTPConnection) {
        guard let params = bridge.readSettings(channel) else {
            return c.respondError(503, "The HomeBase didn't answer. The camera may be asleep or offline; try again.")
        }
        c.respondJSON(["groups": settingsJSON(channel, params), "info": CameraHealth(params: params).json])
    }

    /// Sends the change, then reads it back from the HomeBase, as the Mac app does.
    private func writeSetting(_ request: HTTPRequest, _ channel: UInt8, _ c: HTTPConnection) {
        guard let body = request.json(), let id = body["id"] as? String else { return c.respondError(400, "id and value") }
        let value: Int
        if let b = body["value"] as? Bool { value = b ? 1 : 0 }
        else if let n = body["value"] as? NSNumber { value = n.intValue }
        else { return c.respondError(400, "value") }
        let deviceType = bridge.camera(channel)?.deviceType
        guard let setting = CameraSettingsCatalog.settings(forDeviceType: deviceType).first(where: { $0.id == id }) else {
            return c.respondError(404, "No such setting")
        }
        let (stream, fresh) = bridge.controlStream(channel)
        if fresh { _ = bridge.readSettings(channel) }   // a new session: wait until it answers
        let label = CameraSettingsCatalog.displayLabel(setting)
        guard blocking({ await stream.writeSetting(setting, deviceType: deviceType, value: value) }) else {
            return c.respondJSON(["message": "Eufynized can't set \(label) to that value on this camera."], status: 422)
        }
        if CameraSettingsCatalog.writeOnlyKeys.contains(setting.key) { bridge.prefs.remember(value, key: setting.key, channel: channel) }
        Thread.sleep(forTimeInterval: 1.5)
        guard let params = bridge.readSettings(channel) else {
            return c.respondJSON(["message": "Couldn't confirm \(label); the HomeBase didn't answer."], status: 202)
        }
        var reply: [String: Any] = ["groups": settingsJSON(channel, params)]
        if CameraSettingsCatalog.value(of: setting, in: params, deviceType: deviceType)?.intValue != value {
            reply["message"] = "\(label) didn't change. The camera may be asleep or busy; try again."
        }
        c.respondJSON(reply)
    }

    // MARK: Events

    private func events(_ request: HTTPRequest, _ c: HTTPConnection) {
        let now = Date()
        let to = Double(request.query["to"] ?? "").map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
        let from = Double(request.query["from"] ?? "").map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? Calendar.current.startOfDay(for: now)
        let serials = bridge.config.cameras.map(\.serial)
        let recordings = bridge.recordings
        let result: Result<[EufyEvent], Error> = blocking {
            // The HomeBase files events by its local day; querying by the wrong zone could miss the range's edges, so
            // without a known zone, one extra day each side. The exact range is applied after.
            do {
                // Home Assistant passes its time zone to add-ons (TZ); without one, pad.
                let pad: TimeInterval = (ProcessInfo.processInfo.environment["TZ"] ?? "").isEmpty ? 86400 : 0
                let all = try await recordings.events(cameraSerials: serials, from: from.addingTimeInterval(-pad),
                                                      to: to.addingTimeInterval(pad))
                return .success(all.filter { $0.startTime >= from && $0.startTime <= to })
            }
            catch { return .failure(error) }
        }
        switch result {
        case .success(let events):
            c.respondJSON(["events": events.map { e -> [String: Any] in
                let camera = bridge.config.cameras.first { $0.serial == e.deviceSerial }
                var json: [String: Any] = ["id": String(e.recordID), "serial": e.deviceSerial, "camera": camera?.name ?? e.deviceSerial,
                                           "start": e.startTime.timeIntervalSince1970 * 1000, "end": e.endTime.timeIntervalSince1970 * 1000,
                                           "kind": e.kind.rawValue, "label": e.kindLabel, "path": e.storagePath, "bytes": e.byteSize]
                if let ch = e.channel ?? camera?.channel { json["channel"] = ch }
                if let thumb = e.thumbnailPath { json["thumb"] = thumb }
                return json
            }])
        case .failure(let error):
            c.respondError(503, error.localizedDescription)
        }
    }

    private func cacheFile(_ key: String, ext: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return bridge.cacheDir.appendingPathComponent(String(safe.suffix(120)) + "." + ext)
    }

    private func eventImage(_ request: HTTPRequest, _ c: HTTPConnection) {
        guard let path = request.query["path"], !path.isEmpty else { return c.respondError(400, "path") }
        let file = cacheFile(path, ext: "jpg")
        if let cached = try? Data(contentsOf: file) { return c.respond(200, cached, type: "image/jpeg", headers: ["Cache-Control": "max-age=86400"]) }
        let recordings = bridge.recordings
        guard let jpeg = blocking({ try? await recordings.image(path: path) }) else { return c.respondError(503, "No snapshot") }
        try? jpeg.write(to: file)
        c.respond(200, jpeg, type: "image/jpeg")
    }

    private let clipLock = NSLock()
    private var clipsInFlight: [String: DispatchSemaphore] = [:]
    /// Bytes received so far per clip being downloaded, for the page's progress bar.
    private var clipProgress: [String: Int] = [:]

    /// The event's clip as MP4 (downloaded from the HomeBase once, remuxed without re-encoding, then cached),
    /// with byte ranges so Safari and iPhone can play it.
    private func eventClip(_ request: HTTPRequest, _ c: HTTPConnection) {
        guard let path = request.query["path"], let channel = UInt8(request.query["channel"] ?? "") else { return c.respondError(400, "path, channel") }
        let file = cacheFile(path, ext: "mp4")
        if !FileManager.default.fileExists(atPath: file.path) {
            // One download per clip, even when the browser asks several times at once.
            let (gate, mine): (DispatchSemaphore, Bool) = clipLock.withLock {
                if let g = clipsInFlight[path] { return (g, false) }
                let g = DispatchSemaphore(value: 0); clipsInFlight[path] = g; return (g, true)
            }
            if mine {
                defer { clipLock.withLock { clipsInFlight[path] = nil; clipProgress[path] = nil }; gate.signal() }
                guard let mp4 = downloadClip(channel: channel, path: path) else { return c.respondError(503, "The HomeBase didn't send the clip") }
                try? mp4.write(to: file)
            } else {
                gate.wait(); gate.signal()
            }
        }
        guard let data = try? Data(contentsOf: file) else { return c.respondError(503, "The HomeBase didn't send the clip") }
        serveRange(data, type: "video/mp4", request: request, c)
    }

    private func downloadClip(channel: UInt8, path: String) -> Data? {
        let recordings = bridge.recordings
        guard let clip = blocking({
            try? await recordings.downloadClip(channel: channel, storagePath: path) { [weak self] _, bytes in
                self?.clipLock.withLock { self?.clipProgress[path] = bytes }
            }
        }) else { return nil }
        let muxer = MPEGTSMuxer()
        var ts = Data()
        // Interleave audio and video by capture time.
        var a = 0
        for frame in clip.video {
            while a < clip.audio.count, clip.audio[a].timestampMs <= frame.timestampMs {
                ts += muxer.audio(clip.audio[a].data, captureMs: clip.audio[a].timestampMs); a += 1
            }
            ts += muxer.video(frame.data, captureMs: frame.timestampMs, keyframe: frame.keyframe)
        }
        while a < clip.audio.count { ts += muxer.audio(clip.audio[a].data, captureMs: clip.audio[a].timestampMs); a += 1 }
        let tag = muxer.codec == .h265 ? ["-tag:v", "hvc1"] : []
        let out = bridge.cacheDir.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        guard FFmpeg.run(["-y", "-fflags", "+genpts", "-f", "mpegts", "-i", "pipe:0", "-c", "copy"] + tag +
                         ["-movflags", "+faststart", out.path], input: ts) != nil else { return nil }
        return try? Data(contentsOf: out)
    }

    private func serveRange(_ data: Data, type: String, request: HTTPRequest, _ c: HTTPConnection) {
        guard let range = request.headers["range"], range.hasPrefix("bytes=") else {
            // The page's own files must never be stale after an update; pictures and fonts can be kept a day.
            let page = ["text/html", "text/javascript", "application/javascript", "text/css"].contains { type.hasPrefix($0) }
            return c.respond(200, data, type: type, headers: ["Accept-Ranges": "bytes", "Cache-Control": page ? "no-cache" : "max-age=86400"])
        }
        let spec = range.dropFirst(6).split(separator: ",").first ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        var start = bounds.first.flatMap { $0 } ?? 0
        var end = bounds.count > 1 ? (bounds[1] ?? data.count - 1) : data.count - 1
        if bounds.first.flatMap({ $0 }) == nil, bounds.count > 1, let suffix = bounds[1] { start = max(0, data.count - suffix); end = data.count - 1 }
        end = min(end, data.count - 1)
        guard start <= end, start < data.count else {
            return c.respond(416, Data(), type: type, headers: ["Content-Range": "bytes */\(data.count)"])
        }
        c.respond(206, data.subdata(in: start..<(end + 1)), type: type,
                  headers: ["Accept-Ranges": "bytes", "Content-Range": "bytes \(start)-\(end)/\(data.count)"])
    }

    // MARK: Alerts

    /// Server-sent events: each camera event as it happens, for the page's toasts.
    /// `all`: every event with `alert`/`push` flags (for the Home Assistant integration); otherwise only
    /// the ones that pass the alert settings (the page's toasts).
    private func alertStream(_ c: HTTPConnection, all: Bool) {
        guard c.beginStream(type: "text/event-stream", headers: ["X-Accel-Buffering": "no"]) else { return }
        let queue = StreamSubscriber(format: .ts)
        let send = { (json: [String: Any]) in
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                queue.pushRaw(Data("data: ".utf8) + data + Data("\n\n".utf8))
            }
        }
        let id = all ? alerts.listenToAll(send) : alerts.listen { send($0.json) }
        defer { alerts.stopListening(id); queue.close() }
        while true {
            let chunk = queue.next(timeout: 20) ?? Data(": keep-alive\n\n".utf8)
            if !c.write(chunk) { return }
        }
    }

    // MARK: Static files

    private func serveStatic(_ path: String, _ c: HTTPConnection) {
        let relative = path == "/" || path.isEmpty ? "index.html" : String(path.drop(while: { $0 == "/" }))
        guard !relative.contains("..") else { return c.respondError(400, "Bad path") }
        let file = bridge.wwwDir.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: file) else { return c.respondError(404, "Not found") }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                     "svg": "image/svg+xml", "png": "image/png", "json": "application/json", "webmanifest": "application/manifest+json"]
        // Never let a browser or the Home Assistant app keep an old copy of the page after an update.
        c.respond(200, data, type: types[file.pathExtension] ?? "application/octet-stream", headers: ["Cache-Control": "no-cache"])
    }
}

/// Two-way audio from the browser: the page sends 16 kHz mono PCM in short chunks; ffmpeg turns it into the
/// ADTS AAC the camera's speaker takes.
final class TalkbackSessions {
    private final class Session {
        let process = Process()
        let input = Pipe()
        let stream: EufyLiveStream
        var lastAudio = Date()
        init(stream: EufyLiveStream) { self.stream = stream }
    }
    private let lock = NSLock()
    private var sessions: [UInt8: Session] = [:]

    func handle(_ action: String, channel: UInt8, body: Data, bridge: Bridge, _ c: HTTPConnection) {
        switch action {
        case "start":
            stop(channel)
            guard let feed = bridge.hub.feed(channel) else { return c.respondError(409, "Open the camera's live view first") }
            let session = Session(stream: feed.stream)
            let output = Pipe()
            session.process.executableURL = URL(fileURLWithPath: FFmpeg.binary)
            session.process.arguments = ["-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "pipe:0",
                                         "-c:a", "aac", "-b:a", "32k", "-ar", "16000", "-ac", "1", "-f", "adts", "pipe:1"]
            session.process.standardInput = session.input
            session.process.standardOutput = output
            session.process.standardError = FileHandle.nullDevice
            do { try session.process.run() } catch { return c.respondError(500, "ffmpeg: \(error)") }
            feed.stream.startTalkback()
            lock.withLock { sessions[channel] = session }
            Thread.detachNewThread {
                var pending = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending += chunk
                    // Split into ADTS frames (the length is in the 7-byte header).
                    while pending.count >= 7 {
                        let b = [UInt8](pending.prefix(7))
                        guard b[0] == 0xFF, b[1] & 0xF0 == 0xF0 else { pending.removeFirst(); continue }
                        let length = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | (Int(b[5]) >> 5)
                        guard length >= 7, pending.count >= length else { break }
                        session.stream.sendTalkbackAudio(Data(pending.prefix(length)))
                        pending.removeFirst(length)
                    }
                }
            }
            c.respondJSON(["ok": true])
        case "audio":
            guard let session = lock.withLock({ sessions[channel] }) else { return c.respondError(409, "Talkback isn't on") }
            session.lastAudio = Date()
            try? session.input.fileHandleForWriting.write(contentsOf: body)
            c.respondJSON(["ok": true])
        case "stop":
            stop(channel)
            c.respondJSON(["ok": true])
        default:
            c.respondError(404, "Not found")
        }
    }

    /// Plays a stored reply through the camera's speaker: ffmpeg turns the file into ADTS frames, sent at the
    /// speed they play (64 ms each) so the camera's small buffer keeps up, then talkback ends.
    func play(_ file: URL, on stream: EufyLiveStream, channel: UInt8) {
        stop(channel)
        Thread.detachNewThread {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: FFmpeg.binary)
            process.arguments = ["-hide_banner", "-loglevel", "error", "-i", file.path,
                                 "-c:a", "aac", "-b:a", "32k", "-ar", "16000", "-ac", "1", "-f", "adts", "pipe:1"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stream.startTalkback()
            Thread.sleep(forTimeInterval: 0.4)
            var pending = data
            while pending.count >= 7 {
                let b = [UInt8](pending.prefix(7))
                guard b[0] == 0xFF, b[1] & 0xF0 == 0xF0 else { pending.removeFirst(); continue }
                let length = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | (Int(b[5]) >> 5)
                guard length >= 7, pending.count >= length else { break }
                stream.sendTalkbackAudio(Data(pending.prefix(length)))
                pending.removeFirst(length)
                Thread.sleep(forTimeInterval: 0.064)
            }
            Thread.sleep(forTimeInterval: 0.5)
            stream.stopTalkback()
        }
    }

    private func stop(_ channel: UInt8) {
        guard let session = lock.withLock({ sessions.removeValue(forKey: channel) }) else { return }
        try? session.input.fileHandleForWriting.close()
        session.process.terminate()
        session.stream.stopTalkback()
    }
}

extension Routes {
    /// Opens its own session for `channel` and records when the first frame and each new resolution arrive,
    /// until 4K (3840 wide) or `seconds`. For measuring how fast a camera reaches full size.
    func rampExperiment(_ channel: UInt8, pre: Bool, streamType: Int, quality: StreamQuality?, seconds: Double) -> [String: Any] {
        var config = bridge.streamConfig(channel: channel, video: true)
        config.audio = false
        config.quality = quality
        config.qualityBeforeStart = pre
        config.streamType = streamType
        #if canImport(CoreMedia)
        let stream = EufyLiveStream(config: config, onSample: { _ in })
        #else
        let stream = EufyLiveStream(config: config)
        #endif
        let log = RampLog()
        stream.onVideoFrame = { _, _, keyframe, size in log.add(size, keyframe: keyframe) }
        stream.start()
        _ = log.reached4K.wait(timeout: .now() + seconds)
        stream.stop()
        return ["channel": Int(channel), "pre": pre, "streamtype": streamType, "quality": quality?.rawValue ?? "none",
                "steps": log.steps, "frames": log.frames, "elapsed": RampLog.round(Date().timeIntervalSince(log.start))]
    }
}

/// Resolution changes seen by `rampExperiment`, with seconds since the start.
final class RampLog: @unchecked Sendable {
    let start = Date()
    let reached4K = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var last: String?
    private var _steps: [[String: Any]] = []
    private var _frames = 0

    var steps: [[String: Any]] { lock.withLock { _steps } }
    var frames: Int { lock.withLock { _frames } }

    static func round(_ t: TimeInterval) -> Double { (t * 10).rounded() / 10 }

    func add(_ size: String?, keyframe: Bool) {
        lock.withLock {
            _frames += 1
            guard let size, size != last else { return }
            last = size
            _steps.append(["t": Self.round(Date().timeIntervalSince(start)), "size": size, "keyframe": keyframe])
            if size.hasPrefix("3840") { reached4K.signal() }
        }
    }
}

extension Routes {
    /// Commands the probe may send: the reads being mapped and snooze. Never reboot, reset, format or unbind.
    static let probeAllowed: Set<Int> = [1307, 1192, 1271, 1274, 1211, 1176, 1152, 1103, 1306, 6445]

    func probe(_ request: HTTPRequest, _ c: HTTPConnection) {
        guard let body = request.json(), let watcher = alerts.eventWatcher else { return c.respondError(400, "JSON body") }
        let channel = UInt8((body["channel"] as? NSNumber)?.intValue ?? 0)
        let seconds = (body["seconds"] as? NSNumber)?.doubleValue ?? 6
        let send: (HomeBaseSession) -> Void
        if let cmd = (body["cmd"] as? NSNumber)?.intValue {
            guard Self.probeAllowed.contains(cmd), !CameraSettingsCatalog.forbiddenCommands.contains(cmd) else { return c.respondError(403, "cmd") }
            // The event database (1306): reads only. Its delete (10001) and update (10002) never go out.
            if cmd == 1306 {
                let rawInner = (body["raw"] as? String).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let inner = ((rawInner ?? body["payload"] as? [String: Any])?["cmd"] as? NSNumber)?.intValue ?? -1
                guard [10000, 10005, 10006, 10008, 10009, 10011, 10012, 10013, 10017].contains(inner) else { return c.respondError(403, "database reads only") }
            }
            // "raw": the payload as text, sent exactly as given (key order kept).
            let payload = (body["raw"] as? String)
                ?? body["payload"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            send = { $0.sendSetPayload(cmd: cmd, channel: channel, mValue3: 0, payloadJSON: payload) }
        } else if let cmd = (body["level2"] as? NSNumber)?.intValue, let hex = body["hex"] as? String {
            guard Self.probeAllowed.contains(cmd), !CameraSettingsCatalog.forbiddenCommands.contains(cmd) else { return c.respondError(403, "cmd") }
            var bytes = Data()
            var i = hex.startIndex
            while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
                if let b = UInt8(hex[i..<j], radix: 16) { bytes.append(b) }
                i = j
            }
            send = { session in
                guard let key = session.level2Key else { return }
                session.connection.sendLevel2Command(UInt16(cmd), channel: channel, plaintext: bytes, level2Key: key)
            }
        } else if let cmd = (body["level2"] as? NSNumber)?.intValue, let json = body["json"] as? String {
            guard Self.probeAllowed.contains(cmd), !CameraSettingsCatalog.forbiddenCommands.contains(cmd) else { return c.respondError(403, "cmd") }
            send = { session in
                guard let key = session.level2Key else { return }
                session.connection.sendLevel2Command(UInt16(cmd), channel: channel, plaintext: Data(json.utf8), level2Key: key)
            }
        } else {
            return c.respondError(400, "cmd or level2")
        }
        guard let frames = blocking({ await watcher.capture(seconds: seconds, send: send) }) else { return c.respondError(503, "not connected") }
        c.respondJSON(frames.map { f -> [String: Any] in
            let text = String(decoding: f.plain.prefix(body["full"] as? Bool == true ? 200_000 : 600), as: UTF8.self).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " ") }
            return ["cmd": Int(f.cmd), "len": f.plain.count, "hex": f.plain.prefix(48).map { String(format: "%02x", $0) }.joined(), "text": text]
        })
    }
}

/// Stored quick replies ("Leave the package by the door"): WAV files in the data folder, 16 kHz mono.
enum QuickReplies {
    static func dir(_ bridge: Bridge) -> URL {
        let d = bridge.dataDir.appendingPathComponent("replies", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func safe(_ name: String) -> String {
        String(name.prefix(60)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "..", with: "-").trimmingCharacters(in: .whitespaces)
    }

    static func list(_ bridge: Bridge) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir(bridge).path)) ?? [])
            .filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) }.sorted()
    }

    static func file(_ bridge: Bridge, name: String) -> URL? {
        let url = dir(bridge).appendingPathComponent(safe(name) + ".wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Converts whatever came in to 16 kHz mono WAV.
    static func save(_ bridge: Bridge, name: String, audio: Data, rawPCM: Bool) -> Bool {
        let input = rawPCM ? ["-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "pipe:0"] : ["-i", "pipe:0"]
        guard let wav = FFmpeg.run(input + ["-ar", "16000", "-ac", "1", "-f", "wav", "pipe:1"], input: audio), wav.count > 100 else { return false }
        return (try? wav.write(to: dir(bridge).appendingPathComponent(safe(name) + ".wav"))) != nil
    }

    static func delete(_ bridge: Bridge, name: String) {
        try? FileManager.default.removeItem(at: dir(bridge).appendingPathComponent(safe(name) + ".wav"))
    }
}

extension Routes {
    /// Serves a whole file, or the byte range a video player asks for.
    func serveFile(_ file: URL, type: String, _ request: HTTPRequest, _ c: HTTPConnection) {
        guard let data = try? Data(contentsOf: file) else { return c.respondError(404, "Not found") }
        if let range = request.headers["range"] ?? request.headers["Range"], range.hasPrefix("bytes=") {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "") ?? 0
            let end = min(data.count - 1, parts.count > 1 ? (Int(parts[1]) ?? data.count - 1) : data.count - 1)
            guard start <= end else { return c.respondError(416, "Range") }
            c.respond(206, data.subdata(in: start ..< end + 1), type: type,
                      headers: ["Content-Range": "bytes \(start)-\(end)/\(data.count)", "Accept-Ranges": "bytes"])
        } else {
            c.respond(200, data, type: type, headers: ["Accept-Ranges": "bytes"])
        }
    }
}
