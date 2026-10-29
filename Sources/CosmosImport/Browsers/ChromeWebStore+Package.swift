import CryptoKit
import Foundation
import Security

/// A Web Store package (CRX3) whose signature was checked: the zip, and the developer's public key, which is what makes
/// the extension's id (and keeps it, written into the manifest as `key`).
public struct VerifiedPackage: Sendable {
    public var zip: Data
    /// The developer's key, DER (SubjectPublicKeyInfo).
    public var publicKey: Data
}

extension ChromeWebStore {
    public enum SignatureError: Error, Equatable {
        /// Not a CRX3 package (an older CRX2, or a bare zip, carries no signature Cosmos can check).
        case notCRX3
        case damaged
        /// The package is signed for another extension than the one asked for.
        case wrongExtension(String)
        /// No signature in it matches its contents and its id.
        case badSignature
    }

    /// The zip of a CRX3 package, once a signature in it is shown to be by the key its id comes from (the first 16 bytes
    /// of that key's SHA-256 are the id), over the package's signed header and its zip, and that id is `expectedID`. So
    /// a package that was changed, or one for another extension, is refused. (The Web Store's own counter-signature is
    /// not checked; the developer's is what ties the contents to the extension.)
    public static func verifiedPackage(_ data: Data, expectedID: String) throws -> VerifiedPackage {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int? {
            guard bytes.count >= at + 4 else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        guard bytes.starts(with: Array("Cr24".utf8)), u32(4) == 3 else { throw SignatureError.notCRX3 }
        guard let headerLength = u32(8), 12 + headerLength <= bytes.count else { throw SignatureError.damaged }
        let header = Array(bytes[12..<(12 + headerLength)])
        let zip = Data(bytes[(12 + headerLength)...])
        guard let fields = Protobuf.fields(header) else { throw SignatureError.damaged }
        guard let signedHeader = fields.first(where: { $0.number == 10000 })?.bytes,
              let crxID = Protobuf.fields(signedHeader)?.first(where: { $0.number == 1 })?.bytes, crxID.count == 16 else {
            throw SignatureError.damaged
        }
        let id = extensionID(hash: crxID)
        guard id == expectedID else { throw SignatureError.wrongExtension(id) }
        var message = Data("CRX3 SignedData\u{0}".utf8)
        withUnsafeBytes(of: UInt32(signedHeader.count).littleEndian) { message.append(contentsOf: $0) }
        message.append(contentsOf: signedHeader)
        message.append(zip)
        // 2: RSA proofs, 3: ECDSA ones; each a public key (1) and a signature (2).
        for field in fields where field.number == 2 || field.number == 3 {
            guard let proof = field.bytes.flatMap(Protobuf.fields),
                  let key = proof.first(where: { $0.number == 1 })?.bytes, let signature = proof.first(where: { $0.number == 2 })?.bytes,
                  Array(SHA256.hash(data: key).prefix(16)) == crxID else { continue }
            let rsa = field.number == 2
            guard let raw = SubjectPublicKeyInfo.key(key),
                  let secKey = SecKeyCreateWithData(Data(raw) as CFData, [kSecAttrKeyType: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
                                                                          kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { continue }
            let algorithm: SecKeyAlgorithm = rsa ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
            if SecKeyVerifySignature(secKey, algorithm, message as CFData, Data(signature) as CFData, nil) {
                return VerifiedPackage(zip: zip, publicKey: Data(key))
            }
        }
        throw SignatureError.badSignature
    }

    /// Writes the package's key into the unpacked extension's manifest, as Chrome does when it installs one: Chromium then
    /// gives the copy the Web Store's id, whatever folder it is in, so it keeps its storage across updates, and sign-in
    /// pages, websites and companion apps that know it by that id still do.
    public static func writeKey(_ key: Data, intoManifestIn folder: URL) throws {
        let file = folder.appendingPathComponent("manifest.json")
        guard var manifest = ChromiumExtensionScanner.readManifest(folder) else { throw SignatureError.damaged }
        manifest["key"] = key.base64EncodedString()
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: file)
    }
}

/// The few protobuf wire forms a CRX header uses: varints and length-delimited fields.
enum Protobuf {
    struct Field { var number: Int; var bytes: [UInt8]? }

    static func fields(_ b: [UInt8]) -> [Field]? {
        var out: [Field] = [], i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let tag = varint() else { return nil }
            switch tag & 7 {
            case 0: guard varint() != nil else { return nil }; out.append(Field(number: tag >> 3, bytes: nil))
            case 2:
                guard let n = varint(), n >= 0, n <= b.count - i else { return nil }
                out.append(Field(number: tag >> 3, bytes: Array(b[i..<(i + n)])))
                i += n
            default: return nil
            }
        }
        return out
    }
}

/// The key inside a DER SubjectPublicKeyInfo (what CRX headers carry): the BIT STRING after the algorithm, which is
/// what the Security framework takes (PKCS #1 for RSA, the X9.63 point for EC).
enum SubjectPublicKeyInfo {
    static func key(_ der: [UInt8]) -> [UInt8]? {
        var i = 0
        func element() -> (tag: UInt8, body: Range<Int>)? {
            guard i + 2 <= der.count else { return nil }
            let tag = der[i]; i += 1
            var length = Int(der[i]); i += 1
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n > 0, n <= 4, i + n <= der.count else { return nil }
                length = der[i..<(i + n)].reduce(0) { $0 << 8 | Int($1) }
                i += n
            }
            guard i + length <= der.count else { return nil }
            defer { i += length }
            return (tag, i..<(i + length))
        }
        guard let outer = element(), outer.tag == 0x30 else { return nil }
        i = outer.body.lowerBound
        guard let algorithm = element(), algorithm.tag == 0x30, let bits = element(), bits.tag == 0x03, bits.body.count > 1,
              der[bits.body.lowerBound] == 0 else { return nil }
        return Array(der[(bits.body.lowerBound + 1)..<bits.body.upperBound])
    }
}
