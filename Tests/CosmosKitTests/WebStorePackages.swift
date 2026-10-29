import CryptoKit
import Foundation
import Security
import Testing
@testable import CosmosImport

/// Chrome Web Store packages made here as the Web Store makes them (CRX3: a protobuf header with the developer's
/// signature over a signed header and the zip), with a key of the test's.
enum WebStorePackages {
    static func varint(_ n: Int) -> [UInt8] {
        var n = n, out: [UInt8] = []
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        return out
    }
    static func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(bytes.count) + bytes }

    /// DER of a SubjectPublicKeyInfo for an RSA key in PKCS #1 form.
    static func spki(rsa pkcs1: [UInt8]) -> [UInt8] {
        func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            let n = body.count
            let length: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
            return [tag] + length + body
        }
        let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        return der(0x30, der(0x30, rsaEncryption) + der(0x03, [0] + pkcs1))
    }

    /// A developer: a signing key, its public half as the Web Store keeps it, and the extension id that follows from it.
    struct Developer {
        let privateKey: SecKey
        let key: [UInt8]
        var id: String { ChromeWebStore.extensionID(ofKey: key) }

        init() throws {
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
            privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
            let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
            let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
            key = spki(rsa: [UInt8](pkcs1))
        }

        /// A CRX3 of `zip` for this developer's extension; `signedZip` is what the signature covers (the zip, unless a test
        /// changes it), `claimedID` the id the signed header names (this developer's, unless a test changes it).
        func package(zip: Data, signedZip: Data? = nil, claimedID: [UInt8]? = nil) throws -> Data {
            let crxID = claimedID ?? Array(SHA256.hash(data: key).prefix(16))
            let signedHeader = field(1, crxID)
            var message = Data("CRX3 SignedData\u{0}".utf8)
            withUnsafeBytes(of: UInt32(signedHeader.count).littleEndian) { message.append(contentsOf: $0) }
            message.append(contentsOf: signedHeader)
            message.append(signedZip ?? zip)
            let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil) as Data?)
            let header = field(2, field(1, key) + field(2, [UInt8](signature))) + field(10000, signedHeader)
            var data = Data("Cr24".utf8)
            for n in [UInt32(3), UInt32(header.count)] { withUnsafeBytes(of: n.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: header)
            data.append(zip)
            return data
        }

        /// A package of the extension whose files are `files` (name: contents).
        func package(files: [String: String]) throws -> Data { try package(zip: try WebStorePackages.zip(files)) }
    }

    /// A zip of `files`, as ditto makes one.
    static func zip(_ files: [String: String]) throws -> Data {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-crx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = work.appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        let zip = work.appendingPathComponent("extension.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: zip)
    }
}
