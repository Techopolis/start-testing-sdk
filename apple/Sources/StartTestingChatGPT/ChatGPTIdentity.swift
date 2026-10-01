import Foundation
import Security
import StartTestingCore

/// Verifies an RS256 ID token against OpenAI's published keys.
enum ChatGPTIdentity {
  static func decode(_ part: Substring) -> Data? {
    var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    return Data(base64Encoded: text)
  }
  private static func length(_ count: Int) -> [UInt8] {
    if count < 128 { return [UInt8(count)] }
    var bytes: [UInt8] = []
    var value = count
    while value > 0 {
      bytes.insert(UInt8(value & 0xff), at: 0)
      value >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }
  private static func integer(_ data: Data) -> [UInt8] {
    var bytes = Array(data.drop(while: { $0 == 0 }))
    if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
    return [0x02] + length(bytes.count) + bytes
  }
  /// PKCS#1 RSAPublicKey from a JWK modulus and exponent.
  static func publicKey(modulus: Data, exponent: Data) -> SecKey? {
    let body = integer(modulus) + integer(exponent)
    let der = Data([0x30] + length(body.count) + body)
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
  }
  static func verify(
    token: String, keys: [String: any Sendable], clientID: String, nonce: String?, now: Date
  ) throws -> (subject: String, email: String) {
    let failure = SDKError.unavailable("ChatGPT identity verification failed.")
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let headerData = decode(parts[0]), let claimData = decode(parts[1]),
      let signature = decode(parts[2]),
      let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      let claims = try? JSONSerialization.jsonObject(with: claimData) as? [String: Any],
      header["alg"] as? String == "RS256", let kid = header["kid"] as? String, !kid.isEmpty,
      let list = keys["keys"] as? [[String: Any]]
    else { throw failure }
    let matches = list.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }
    guard matches.count == 1, let n = matches[0]["n"] as? String, let e = matches[0]["e"] as? String,
      let modulus = decode(Substring(n)), let exponent = decode(Substring(e)),
      modulus.count >= 256, let key = publicKey(modulus: modulus, exponent: exponent),
      SecKeyVerifySignature(
        key, .rsaSignatureMessagePKCS1v15SHA256,
        Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil)
    else { throw failure }
    let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
    guard claims["iss"] as? String == ChatGPT.issuer, audience.contains(clientID),
      let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
      let subject = claims["sub"] as? String, !subject.isEmpty,
      nonce == nil || claims["nonce"] as? String == nonce,
      (claims["azp"] as? String ?? clientID) == clientID
    else { throw failure }
    return (subject, claims["email"] as? String ?? "")
  }
}
