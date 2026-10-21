import Foundation
import CryptoKit
import CommonCrypto
import Security

/// 自定义源脚本 `lx.utils.crypto` 的 Swift 实现。
/// 语义对齐 `src/main/modules/userApi/renderer/preload.js` 的 Node 实现：
/// - `aesEncrypt(buffer, mode, key, iv)` → Node `createCipheriv(mode, key, iv)`，PKCS7 padding
/// - `rsaEncrypt(buffer, key)` → `publicEncrypt({ key, padding: RSA_NO_PADDING })`（左补零到 block size）
/// - `randomBytes(size)` → `crypto.randomBytes`
/// - `md5(str)` → `createHash('md5').update(str).digest('hex')`
enum CryptoBridge {

    // MARK: - md5

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - randomBytes

    static func randomBytes(_ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { return [] }
        return bytes
    }

    // MARK: - Hash（md5 / sha1）

    /// 供 bundle 的 crypto shim 使用：对原始字节计算 hash 并返回 hex
    static func hash(_ algorithm: String, _ bytes: [UInt8]) -> String? {
        let data = Data(bytes)
        let digest: [UInt8]
        switch algorithm.lowercased() {
        case "md5":
            digest = Array(Insecure.MD5.hash(data: data))
        case "sha1":
            digest = Array(Insecure.SHA1.hash(data: data))
        default:
            return nil
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1(_ text: String) -> String? { hash("sha1", Array(text.utf8)) }

    // MARK: - AES（Node createCipheriv/createDecipheriv 兼容：CBC/ECB + PKCS7）

    static func aesEncrypt(_ data: [UInt8], mode: String, key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        aesCrypt(CCOperation(kCCEncrypt), data, mode: mode, key: key, iv: iv)
    }

    static func aesDecrypt(_ data: [UInt8], mode: String, key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        aesCrypt(CCOperation(kCCDecrypt), data, mode: mode, key: key, iv: iv)
    }

    private static func aesCrypt(_ operation: CCOperation, _ data: [UInt8], mode: String, key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        let mode = mode.lowercased()
        guard mode.hasPrefix("aes-") else { return nil }
        let isECB = mode.contains("ecb")
        guard [16, 24, 32].contains(key.count) else { return nil }
        // 与 Node 一致：mode 中声明的位宽必须与 key 长度匹配
        if let bits = mode.split(separator: "-").compactMap({ Int($0) }).first,
           bits == 128 || bits == 192 || bits == 256,
           bits / 8 != key.count {
            return nil
        }
        if !isECB && iv.count != 16 { return nil }

        var cryptor: CCCryptorRef?
        let status: CCCryptorStatus = key.withUnsafeBufferPointer { keyPointer in
            iv.withUnsafeBufferPointer { ivPointer in
                CCCryptorCreateWithMode(
                    operation,
                    CCMode(isECB ? kCCModeECB : kCCModeCBC),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccPKCS7Padding),
                    isECB ? nil : ivPointer.baseAddress,
                    keyPointer.baseAddress,
                    keyPointer.count,
                    nil, 0, 0, 0,
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        if !data.isEmpty {
            let updateStatus = output.withUnsafeMutableBufferPointer { outPointer in
                data.withUnsafeBufferPointer { inPointer in
                    CCCryptorUpdate(cryptor, inPointer.baseAddress, inPointer.count, outPointer.baseAddress, outPointer.count, &moved)
                }
            }
            guard updateStatus == kCCSuccess else { return nil }
        }
        var finalMoved = 0
        let finalStatus = output.withUnsafeMutableBufferPointer { outPointer in
            CCCryptorFinal(cryptor, outPointer.baseAddress! + moved, outPointer.count - moved, &finalMoved)
        }
        guard finalStatus == kCCSuccess else { return nil }
        return Array(output[0..<(moved + finalMoved)])
    }

    // MARK: - RSA raw（RSA_NO_PADDING）

    static func rsaEncrypt(_ data: [UInt8], pem: String) -> [UInt8]? {
        guard let der = pemToDER(pem) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
            return nil
        }
        let blockSize = SecKeyGetBlockSize(key)
        guard blockSize > 0, data.count <= blockSize else { return nil }
        var padded = [UInt8](repeating: 0, count: blockSize)
        padded.replaceSubrange((blockSize - data.count)..<blockSize, with: data)
        let algorithm = SecKeyAlgorithm.rsaEncryptionRaw
        guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else { return nil }
        var encryptError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, Data(padded) as CFData, &encryptError) else {
            return nil
        }
        return Array(encrypted as Data)
    }

    private static func pemToDER(_ pem: String) -> [UInt8]? {
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.contains("-----") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return nil }
        return Array(data)
    }
}
