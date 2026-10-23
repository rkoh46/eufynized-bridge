import Foundation

/// Settings the eufy app's Power Manager offers the eufyCam 3 family (S3 Pro) that eufy-security-client doesn't
/// know. Found by decompiling the app (docs/homebase-research): `ECCamPowerSettingVC::switchWirePowerMode:` sends
/// SET_PAYLOAD inner cmd 6445 `{"source": 1 | 2}` (1 Battery, 2 Direct power; the camera answers `result: 0`),
/// and the app's wired-mode screen also sets continuous recording (6010/6011, as on the indoor cameras).
extension CameraSettingsCatalog {
    static let eufyCam3PowerSettings: [CameraSetting] = [
        CameraSetting(id: "powerSourceMode", label: "Power", group: "Power", key: 6445,
                      kind: .choice([(1, "Battery"), (2, "Direct power")]), writable: true),
        CameraSetting(id: "continuousRecording", label: "Continuous recording", group: "Recording", key: 6010, kind: .toggle, writable: true),
        CameraSetting(id: "continuousRecordingType", label: "Continuous recording mode", group: "Recording", key: 6011,
                      kind: .choice([(0, "Always"), (1, "Schedule")]), writable: true),
    ]

    static var eufyCam3PowerRecipes: [String: CameraSettingWriteRecipe] {
        var out: [String: CameraSettingWriteRecipe] = [
            "powerSourceMode": .perValue([
                1: [CameraSettingWriteFrame(form: .setPayload, command: 1350,
                                            body: "{\"account_id\":\"{account}\",\"cmd\":6445,\"mValue3\":0,\"payload\":{\"source\":1}}")],
                2: [CameraSettingWriteFrame(form: .setPayload, command: 1350,
                                            body: "{\"account_id\":\"{account}\",\"cmd\":6445,\"mValue3\":0,\"payload\":{\"source\":2}}")],
            ]),
        ]
        // Continuous recording goes out the same way as on the indoor cameras (eufy-security-client sends every
        // family's 6010/6011 through the 1700 payload); borrow their recipe.
        if let indoor = recipes.values.first(where: { $0["continuousRecording"] != nil }) {
            out["continuousRecording"] = indoor["continuousRecording"]
            out["continuousRecordingType"] = indoor["continuousRecordingType"]
        }
        return out
    }

    /// Settings the camera never reports back (the Power Manager's power source): the last value written stands
    /// in for the reading. Callers keep it and merge it into the parameters with `merging(_:remembered:)`.
    public static let writeOnlyKeys: Set<Int> = [6445]

    public static func merging(_ params: [Int: String], remembered: [Int: Int]) -> [Int: String] {
        var out = params
        for (key, value) in remembered where writeOnlyKeys.contains(key) && out[key] == nil { out[key] = String(value) }
        return out
    }
}

/// A camera's activity zones: polygons on a 1000×1000 grid over the picture (the HomeBase reports them as
/// base64 JSON in parameter 1204, `{"Normalized":1,"polygens":[{"points":[{"x":…,"y":…}]}]}`; the app writes
/// them with the 1700 payload `{"commandType":6042,"data":{…}}`, CMD_INDOOR_DET_SET_ACTIVE_ZONE).
public struct ActivityZones: Sendable, Equatable {
    public var polygons: [[(x: Int, y: Int)]]

    public init(polygons: [[(x: Int, y: Int)]]) { self.polygons = polygons }

    public init?(params: [Int: String]) {
        guard let raw = params[1204], !raw.isEmpty, let data = Data(base64Encoded: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let polys = json["polygens"] as? [[String: Any]] else { return nil }
        polygons = polys.compactMap { p in
            (p["points"] as? [[String: Any]])?.compactMap { pt in
                guard let x = (pt["x"] as? NSNumber)?.intValue, let y = (pt["y"] as? NSNumber)?.intValue else { return nil }
                return (x, y)
            }
        }.filter { $0.count >= 3 }
    }

    public var json: [String: Any] {
        ["Normalized": 1, "polygens": polygons.map { ["points": $0.map { ["x": $0.x, "y": $0.y] }] }]
    }

    /// The 1700 payload that writes these zones.
    public var controlJSON: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["commandType": 6042, "data": json]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func == (a: ActivityZones, b: ActivityZones) -> Bool {
        a.polygons.count == b.polygons.count && zip(a.polygons, b.polygons).allSatisfy { $0.elementsEqual($1) { $0 == $1 } }
    }
}
