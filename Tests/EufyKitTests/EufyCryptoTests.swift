import Testing
import Foundation
import CryptoKit
@testable import EufyKit

// Synthetic, self-consistent vector from eufy-sdk (src/core/__tests__/vector.json); the formula it
// guards was verified against live Eufy traffic.
private let shareKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
private let ts = "1700000000"
private let once = "00112233445566778899aabbccddeeff"
private let bodyB64 = "Dw4NDAsKCQgHBgUEAwIBAON7nAdtN7DzIooLLHfGyy/gYJMK1jWa/qbASxRBJcl6Hw62mx/9J0Bw1nLTUhsURA=="
private let bodyPlaintext = #"{"example":"synthetic-test-vector","n":42}"#
private let signature = "9860cd44b02b7b68e7feb1ea128e87c8304982b3de1250a5b49c0fda96f0ba10"

@Test func decryptsVectorBody() throws {
    let plaintext = try EufyCrypto.decryptBody(bodyB64, shareKeyHex: shareKey)
    #expect(String(decoding: plaintext, as: UTF8.self) == bodyPlaintext)
}

@Test func encryptsVectorBodyWithItsIV() throws {
    let iv = Data(base64Encoded: bodyB64)!.prefix(16)
    #expect(try EufyCrypto.encryptBody(Data(bodyPlaintext.utf8), shareKeyHex: shareKey, iv: iv) == bodyB64)
}

@Test func reproducesVectorSignature() {
    #expect(EufyCrypto.sign(shareKeyHex: shareKey, ts: ts, once: once, encryptedBody: bodyB64) == signature)
}

@Test func emptyBodySignatureOmitsTrailingPlus() {
    let empty = EufyCrypto.sign(shareKeyHex: shareKey, ts: ts, once: once, encryptedBody: nil)
    #expect(empty.count == 64)
    #expect(empty != signature)
    #expect(empty == EufyCrypto.hmacHex(key: Data(shareKey.prefix(32).utf8), message: "\(ts)+\(once)"))
}

@Test func gtokenIsMD5OfUserID() {
    #expect(EufyCrypto.gtoken(userId: "abc") == "900150983cd24fb0d6963f7d28e17f72")
}

@Test func keyExchangeRoundTripsAgainstSimulatedServer() throws {
    let request = try EufyCrypto.prepareKeyExchange()
    #expect(request.keyIdent.count == 32)
    #expect(request.headers["x-encryption-info"] == "algo_ecdh")

    // Act as the server: unwrap the client key, answer with our own wrapped key.
    let localKey = Data(hex: EufyCrypto.megaLocalKeyHex)!
    let blob = Data(base64Encoded: request.encryptedClientPublicKey)!
    let clientHex = String(decoding: try EufyCrypto.aesCBC(encrypt: false, key: localKey, iv: blob.prefix(16), data: blob.dropFirst(16)), as: UTF8.self)
    let clientKey = try P256.KeyAgreement.PublicKey(x963Representation: Data(hex: clientHex)!)
    let server = P256.KeyAgreement.PrivateKey()
    let iv = EufyCrypto.randomBytes(16)
    let wrapped = (iv + (try EufyCrypto.aesCBC(encrypt: true, key: localKey, iv: iv,
                                               data: Data(server.publicKey.x963Representation.hexString.utf8)))).base64EncodedString()

    let clientShare = try EufyCrypto.finishKeyExchange(request, serverPublicKeyBase64: wrapped)
    let serverShare = String(try server.sharedSecretFromKeyAgreement(with: clientKey).withUnsafeBytes { Data($0) }.hexString.prefix(32))
    #expect(clientShare == serverShare)
    #expect(clientShare.count == 32)
}

@Test func loginPasswordDecryptsWithServerSideSecret() throws {
    // We can't hold Eufy's private key, so check the construction with our own "server" key.
    let (clientHex, encrypted) = try EufyCrypto.encryptLoginPassword("hunter2")
    let clientKey = try P256.KeyAgreement.PublicKey(x963Representation: Data(hex: clientHex)!)
    #expect(clientKey.x963Representation.count == 65)
    #expect(Data(base64Encoded: encrypted)?.count == 16)
}

@Test func parsesDeviceListEntry() {
    let device = EufyDevice(json: ["device_sn": "T8162T0000000001", "device_name": "Driveway",
                                   "device_model": "T8162", "station_sn": "T8030T0000000009",
                                   "p2p_did": "EXAMPLE-000000-ABCDE", "device_type": 1])
    #expect(device?.name == "Driveway")
    #expect(device?.stationSerial == "T8030T0000000009")
    #expect(device?.productName == "eufyCam S3 Pro")
    #expect(device?.isStation == false)

    // HomeBase-attached cameras carry the station in parent_sn, with station_sn empty.
    let attached = EufyDevice(json: ["device_sn": "T8113T0000000002", "device_model": "T8113-V",
                                     "parent_sn": "T8030T0000000009", "station_sn": ""])
    #expect(attached?.stationSerial == "T8030T0000000009")
    #expect(attached?.rawFieldNames == ["device_model", "device_sn", "parent_sn", "station_sn"])
    let standalone = EufyDevice(json: ["device_sn": "T8417T0000000003", "parent_sn": "T8417T0000000003"])
    #expect(standalone?.stationSerial == "T8417T0000000003")

    let station = EufyDevice(json: ["device_sn": "T8030T0000000009", "device_model": "T8030"])
    #expect(station?.isStation == true)
    #expect(EufyDevice(json: ["device_name": "no serial"]) == nil)
}

@Test func redactsEchoedTokens() {
    let message = EufyCloudClient.redactingToken("token = abcdefghijklmnop123456, gtoken not equal userid error")
    #expect(!message.contains("abcdefghijklmnop"))
}
