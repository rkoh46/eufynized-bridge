import Foundation
import EufyKit

// Signs in to Eufy (once) and lists the account's devices. Run it in your own terminal:
//   swift run eufynized-login you@example.com [COUNTRY]
// The password is read without echo and never stored; the resulting session is kept in the Keychain.

func prompt(_ text: String) -> String {
    print(text, terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// --fields prints the field names the cloud returns per device (never their values).
let showFields = CommandLine.arguments.contains("--fields")
let args = CommandLine.arguments.filter { $0 != "--fields" }
let email = args.count > 1 ? args[1] : prompt("Eufy account email: ")
guard email.contains("@") else {
    print("usage: eufynized-login [email] [country code, default US]")
    exit(2)
}
let country = args.count > 2 ? args[2] : "US"
let client = EufyCloudClient(configuration: .init(email: email, countryCode: country))

do {
    if await !client.isSignedIn {
        guard let raw = getpass("Eufy password (not shown): ") else { exit(1) }
        var result = try await client.signIn(password: String(cString: raw))
        while result != .signedIn {
            switch result {
            case let .captcha(image, retry):
                let file = FileManager.default.temporaryDirectory.appending(path: "eufy-captcha.png")
                try image?.write(to: file)
                if image != nil { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [file.path]) }
                result = try await client.solveCaptcha(prompt(retry ? "Wrong answer. Captcha (opened in Preview): " : "Captcha (opened in Preview): "))
            case .verificationCodeSent:
                result = try await client.submitVerificationCode(prompt("Verification code sent by Eufy: "))
            case .signedIn:
                break
            }
        }
        print("Signed in. Session saved in your Keychain.")
    }

    let devices = try await client.devices()
    print("\(devices.count) devices:")
    for device in devices {
        let product = device.productName.map { " (\($0))" } ?? ""
        let station = device.isStation || device.stationSerial == device.serial ? "" : "  via \(device.stationSerial)"
        print("- \(device.name): \(device.model)\(product)  \(device.serial)\(station)")
    }
    if showFields {
        print("\nFields returned per device (names only):")
        print(Set(devices.flatMap(\.rawFieldNames)).sorted().joined(separator: ", "))
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
