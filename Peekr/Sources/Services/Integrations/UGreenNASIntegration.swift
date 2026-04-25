import SwiftUI
import CryptoKit
import Security

private enum UGreenAuthError: Error {
    case totpSecretMissing
    case totpFailed
    case rsaFailed
    case loginFailed
}

struct UGreenNASIntegration: ServiceIntegration {
    private static let sessionKeychainPrefix = "ugnas-session-"

    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let hasCredentials = !(service.username ?? "").isEmpty && !(service.password ?? "").isEmpty

        if hasCredentials {
            return try await fetchWithAutoReauth(service: service)
        } else if let token = service.apiKey, !token.isEmpty {
            // Legacy mode: manual session token stored in apiKey
            return try await fetchWithToken(service: service, token: token, isLegacy: true)
        } else {
            return [ServiceMetric(
                label: "Credentials required",
                value: "Swipe \u{2192} Edit",
                icon: "person.fill.questionmark",
                color: .orange
            )]
        }
    }

    // MARK: - Auto-reauth flow

    private func fetchWithAutoReauth(service: Service) async throws -> [ServiceMetric] {
        let cacheKey = Self.sessionKeychainPrefix + service.id.uuidString

        do {
            let token = try await resolveToken(service: service, cacheKey: cacheKey, forceRefresh: false)
            let result = try await fetchWithToken(service: service, token: token, isLegacy: false)
            // Session expired - reauth once
            if result.count == 1 && result[0].icon == "lock.rotation" {
                let fresh = try await resolveToken(service: service, cacheKey: cacheKey, forceRefresh: true)
                return try await fetchWithToken(service: service, token: fresh, isLegacy: false)
            }
            return result
        } catch UGreenAuthError.totpSecretMissing {
            return [ServiceMetric(label: "TOTP Secret needed", value: "Swipe \u{2192} Edit to add", icon: "lock.fill", color: .orange, isAlert: true)]
        } catch UGreenAuthError.totpFailed {
            return [ServiceMetric(label: "2FA failed", value: "Check TOTP secret in Edit", icon: "lock.slash.fill", color: .red, isAlert: true)]
        } catch {
            return [ServiceMetric(label: "Auth failed", value: "Check credentials in Edit", icon: "exclamationmark.lock.fill", color: .red, isAlert: true)]
        }
    }

    private func resolveToken(service: Service, cacheKey: String, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = KeychainHelper.load(account: cacheKey), !cached.isEmpty {
            return cached
        }
        let token = try await authenticate(service: service)
        KeychainHelper.save(token, account: cacheKey)
        return token
    }

    // MARK: - Metrics fetch

    private func fetchWithToken(service: Service, token: String, isLegacy: Bool) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        let t = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token

        async let machineResult  = fetchJSON(url: URL(string: "\(base)/ugreen/v1/sysinfo/machine/common?token=\(t)")!)
        async let firmwareResult = fetchJSON(url: URL(string: "\(base)/ugreen/v1/firmware/version/is_new?token=\(t)")!)
        async let volumesResult  = fetchJSON(url: URL(string: "\(base)/ugreen/v1/filemgr/getVolumes?token=\(t)")!)

        var metrics: [ServiceMetric] = []

        if let machine = try? await machineResult as? [String: Any] {
            if (machine["code"] as? Int) == 1024 {
                let hint = isLegacy ? "Open DevTools Console, look for [setToken] token: and update in Edit" : "Re-authenticating..."
                return [ServiceMetric(label: "Session expired", value: hint, icon: "lock.rotation", color: .orange, isAlert: true)]
            }
            if let data = machine["data"] as? [String: Any] {
                if let common = data["common"] as? [String: Any] {
                    if let v = common["system_version"] as? String, !v.isEmpty {
                        metrics.append(ServiceMetric(label: "OS Version", value: v, icon: "tag.fill", color: .secondary))
                    }
                    if let uptime = common["run_time"] as? Int {
                        metrics.append(ServiceMetric(label: "Uptime", value: formatUptime(uptime), icon: "clock.fill", color: .secondary))
                    }
                }
                if let hw = data["hardware"] as? [String: Any] {
                    if let cpus = hw["cpu"] as? [[String: Any]], let cpu = cpus.first,
                       let temp = cpu["temperature"] as? Int {
                        let color: Color = temp >= 80 ? .red : temp >= 70 ? .orange : .green
                        metrics.append(ServiceMetric(label: "CPU Temp", value: "\(temp)\u{b0}C", icon: "thermometer.medium", color: color, isAlert: temp >= 80))
                    }
                    if let mems = hw["mem"] as? [[String: Any]] {
                        let total = mems.compactMap { $0["size"] as? Int }.reduce(0, +)
                        if total > 0 {
                            metrics.append(ServiceMetric(label: "RAM", value: formatBytes(total), icon: "memorychip.fill", color: .secondary))
                        }
                    }
                }
            }
        }

        if let fw = try? await firmwareResult as? [String: Any],
           let fwData = fw["data"] as? [String: Any],
           let hasVersion = fwData["has_version"] as? Bool, hasVersion {
            let ver = (fwData["publish_version"] as? Int).map { formatFirmwareVersion($0) } ?? "Available"
            metrics.append(ServiceMetric(label: "Update available", value: ver, icon: "arrow.down.circle.fill", color: .orange, isAlert: true))
        }

        if let vols = try? await volumesResult as? [String: Any],
           let volData = vols["data"] as? [String: Any],
           let result = volData["result"] as? [[String: Any]] {
            for vol in result {
                let name    = vol["name"]     as? String ?? "Volume"
                let free    = vol["free"]     as? Int    ?? 0
                let total   = vol["all"]      as? Int    ?? 0
                let desc    = vol["describe"] as? String ?? ""
                let label   = desc.isEmpty ? name : "\(name) (\(desc))"
                let pctUsed = total > 0 ? Double(total - free) / Double(total) : 0
                let color: Color = pctUsed >= 0.9 ? .red : pctUsed >= 0.75 ? .orange : .green
                metrics.append(ServiceMetric(label: label, value: "\(formatBytes(free)) free", icon: "externaldrive.fill", color: color, isAlert: pctUsed >= 0.9))
            }
        }

        return metrics
    }

    // MARK: - Authentication

    private func authenticate(service: Service) async throws -> String {
        let base = baseURL(service)
        guard let username = service.username, !username.isEmpty,
              let password = service.password, !password.isEmpty else {
            throw UGreenAuthError.loginFailed
        }

        // Step 1: Get RSA public key
        var checkReq = URLRequest(url: URL(string: "\(base)/ugreen/v1/verify/check")!)
        checkReq.httpMethod = "POST"
        checkReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        checkReq.httpBody = try JSONSerialization.data(withJSONObject: ["username": username])
        let (_, checkResp) = try await IntegrationHTTP.session.data(for: checkReq)
        guard let httpResp = checkResp as? HTTPURLResponse,
              let rsaB64 = httpResp.value(forHTTPHeaderField: "x-rsa-token"),
              let pemData = Data(base64Encoded: rsaB64),
              let pem = String(data: pemData, encoding: .utf8) else {
            throw UGreenAuthError.loginFailed
        }

        // Step 2: RSA-encrypt password with UGOS custom encoding
        let encrypted = try rsaPKCS1Encrypt(pem: pem, plaintext: Data(password.utf8))
        let encodedPw = ugreenEncode(encrypted.hexString)

        var loginReq = URLRequest(url: URL(string: "\(base)/ugreen/v1/verify/login")!)
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trustKey = "ugnas-trust-\(service.id.uuidString)"
        let storedTrust = KeychainHelper.load(account: trustKey)
        var loginBody: [String: Any] = [
            "username": username, "password": encodedPw,
            "keepalive": false, "otp": true, "is_simple": false
        ]
        if let trust = storedTrust, !trust.isEmpty {
            loginBody["trust_token"] = trust
            loginBody["trust_info"] = ["client_type": "web", "system": "iOS", "dev_name": "Peekr"]
        }
        loginReq.httpBody = try JSONSerialization.data(withJSONObject: loginBody)
        let (loginData, _) = try await IntegrationHTTP.session.data(for: loginReq)
        guard let loginJSON = try JSONSerialization.jsonObject(with: loginData) as? [String: Any],
              let loginBodyResp = loginJSON["data"] as? [String: Any] else {
            throw UGreenAuthError.loginFailed
        }

        // If 2FA is disabled or trust token was accepted, login gives us the token directly
        if let token = loginBodyResp["token"] as? String, !token.isEmpty {
            return token
        }

        guard let tokenId = loginBodyResp["token_id"] as? String else {
            throw UGreenAuthError.loginFailed
        }

        // Step 3: TOTP 2FA - request trust so future logins skip OTP
        let totpSecret = service.apiKey ?? ""
        guard !totpSecret.isEmpty else { throw UGreenAuthError.totpSecretMissing }
        let totpCode = generateTOTP(secret: totpSecret)

        var codeReq = URLRequest(url: URL(string: "\(base)/ugreen/v1/verify/code/login")!)
        codeReq.httpMethod = "POST"
        codeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        codeReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": totpCode, "type": 1, "token_id": tokenId,
            "trust_info": ["client_type": "web", "system": "iOS", "dev_name": "Peekr"],
            "trust": true
        ])
        let (codeData, _) = try await IntegrationHTTP.session.data(for: codeReq)
        guard let codeJSON = try JSONSerialization.jsonObject(with: codeData) as? [String: Any],
              (codeJSON["code"] as? Int) == 200,
              let codeBody = codeJSON["data"] as? [String: Any],
              let token = codeBody["token"] as? String else {
            throw UGreenAuthError.totpFailed
        }
        // Store trust token so next login can skip 2FA
        if let trustToken = codeBody["trust_token"] as? String, !trustToken.isEmpty {
            KeychainHelper.save(trustToken, account: trustKey)
        }
        return token
    }

    // MARK: - RSA PKCS#1 encryption

    private func rsaPKCS1Encrypt(pem: String, plaintext: Data) throws -> Data {
        let stripped = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let spki = Data(base64Encoded: stripped),
              let pkcs1 = extractPKCS1FromSPKI(spki) else {
            throw UGreenAuthError.rsaFailed
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType  as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var cfErr: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &cfErr) else {
            throw UGreenAuthError.rsaFailed
        }
        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, plaintext as CFData, &cfErr) else {
            throw UGreenAuthError.rsaFailed
        }
        return encrypted as Data
    }

    /// Strips the SPKI ASN.1 wrapper to get the raw PKCS#1 RSA public key bytes.
    private func extractPKCS1FromSPKI(_ spki: Data) -> Data? {
        var bytes = [UInt8](spki)
        var idx = 0
        func readLength() -> Int {
            guard idx < bytes.count else { return 0 }
            let first = bytes[idx]; idx += 1
            if first & 0x80 == 0 { return Int(first) }
            let n = Int(first & 0x7f)
            var len = 0
            for _ in 0..<n { guard idx < bytes.count else { break }; len = (len << 8) | Int(bytes[idx]); idx += 1 }
            return len
        }
        // Outer SEQUENCE
        guard idx < bytes.count, bytes[idx] == 0x30 else { return nil }; idx += 1; _ = readLength()
        // AlgorithmIdentifier SEQUENCE - read length and skip
        guard idx < bytes.count, bytes[idx] == 0x30 else { return nil }; idx += 1
        let algLen = readLength(); idx += algLen
        // BIT STRING
        guard idx < bytes.count, bytes[idx] == 0x03 else { return nil }; idx += 1; _ = readLength()
        // Unused bits indicator (always 0x00 for RSA)
        guard idx < bytes.count, bytes[idx] == 0x00 else { return nil }; idx += 1
        return Data(bytes[idx...])
    }

    // MARK: - UGOS custom hex-to-base64 encoding (h() from ugos_main.js)

    private func ugreenEncode(_ hex: String) -> String {
        let b64 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var result = ""
        let chars = Array(hex)
        var pos = 0
        while pos + 3 <= chars.count {
            if let val = Int(String(chars[pos..<pos+3]), radix: 16) {
                result.append(b64[val >> 6])
                result.append(b64[val & 63])
            }
            pos += 3
        }
        let rem = chars.count - pos
        if rem == 1, let val = Int(String(chars[pos]), radix: 16) {
            result.append(b64[val << 2])
        } else if rem == 2, let val = Int(String(chars[pos..<pos+2]), radix: 16) {
            result.append(b64[val >> 2])
            result.append(b64[(val & 3) << 4])
        }
        while result.count % 4 != 0 { result.append("=") }
        return result
    }

    // MARK: - TOTP (RFC 6238, HMAC-SHA1, 6 digits, 30s period)

    private func generateTOTP(secret: String) -> String {
        let cleaned = secret.uppercased().filter { $0 != " " && $0 != "-" }
        guard let keyData = base32Decode(cleaned), !keyData.isEmpty else { return "000000" }
        let counter = UInt64(Date().timeIntervalSince1970 / 30)
        var counterBE = counter.bigEndian
        let counterData = Data(bytes: &counterBE, count: 8)
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let bytes = Array(mac)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let code = (Int(bytes[offset]     & 0x7f) << 24) |
                   (Int(bytes[offset + 1] & 0xff) << 16) |
                   (Int(bytes[offset + 2] & 0xff) <<  8) |
                    Int(bytes[offset + 3] & 0xff)
        return String(format: "%06d", code % 1_000_000)
    }

    private func base32Decode(_ s: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0; var count = 0; var result = Data()
        for ch in s {
            guard ch != "=" else { break }
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            bits = (bits << 5) | alphabet.distance(from: alphabet.startIndex, to: i)
            count += 5
            if count >= 8 {
                count -= 8
                result.append(UInt8(truncatingIfNeeded: bits >> count))
                bits &= (1 << count) - 1
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Formatters

    private func formatUptime(_ seconds: Int) -> String {
        let d = seconds / 86400, h = (seconds % 86400) / 3600
        if d > 0 { return "\(d)d \(h)h" }
        return "\(h)h \((seconds % 3600) / 60)m"
    }

    private func formatBytes(_ bytes: Int) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 1 { return String(format: "%.1f TB", tb) }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }

    private func formatFirmwareVersion(_ v: Int) -> String {
        let s = String(format: "%09d", v)
        return "\(Int(s.prefix(1)) ?? 0).\(Int(s.dropFirst(1).prefix(2)) ?? 0).\(Int(s.dropFirst(3).prefix(2)) ?? 0).\(s.suffix(4))"
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
