import SwiftUI

// In-memory JWT cache. NPM tokens are valid for 1 hour; we cache for 55 minutes.
private actor NPMTokenCache {
    static let shared = NPMTokenCache()
    private init() {}
    private var cache: [String: (token: String, expiry: Date)] = [:]

    func token(for key: String) -> String? {
        guard let entry = cache[key], entry.expiry > Date() else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.token
    }

    func store(_ token: String, for key: String) {
        cache[key] = (token: token, expiry: Date().addingTimeInterval(3300))
    }

    func evict(for key: String) {
        cache.removeValue(forKey: key)
    }
}

struct NginxProxyManagerIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)

        guard let email = service.username, !email.isEmpty,
              let password = service.password, !password.isEmpty else {
            return [ServiceMetric(label: "Login required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }

        // Resolve a valid JWT, using the cache to avoid a round-trip every refresh cycle.
        let cacheKey = "\(email)@\(base)"
        let token: String
        if let cached = await NPMTokenCache.shared.token(for: cacheKey) {
            token = cached
        } else {
            guard let tokenURL = URL(string: "\(base)/api/tokens") else { throw IntegrationError.badURL }
            var tokenReq = URLRequest(url: tokenURL)
            tokenReq.httpMethod = "POST"
            tokenReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            tokenReq.httpBody = try? JSONSerialization.data(withJSONObject: ["identity": email, "secret": password])
            let (tokenData, tokenResp) = try await URLSession.shared.data(for: tokenReq)
            guard let http = tokenResp as? HTTPURLResponse, http.statusCode == 200,
                  let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
                  let newToken = tokenJSON["token"] as? String else {
                return [ServiceMetric(label: "Auth failed", value: "Check credentials", icon: "xmark.circle.fill", color: .red, isAlert: true)]
            }
            token = newToken
            await NPMTokenCache.shared.store(token, for: cacheKey)
        }

        let headers = ["Authorization": "Bearer \(token)"]
        var metrics: [ServiceMetric] = []

        // Proxy hosts + certificates in parallel. Eagerly await both so a 401 on either
        // evicts the cached JWT before propagating up (preventing retry loops with a bad token).
        async let hostsResult = fetchJSON(url: URL(string: "\(base)/api/nginx/proxy-hosts")!, headers: headers)
        async let certsResult = fetchJSON(url: URL(string: "\(base)/api/nginx/certificates")!, headers: headers)

        do {
            let hostsAny = try await hostsResult
            let certsAny = try await certsResult

            if let hosts = hostsAny as? [[String: Any]] {
                let enabled = hosts.filter { ($0["enabled"] as? Int) == 1 }.count
                metrics.append(ServiceMetric(
                    label: "Proxy hosts",
                    value: "\(enabled) enabled / \(hosts.count) total",
                    icon: "arrow.triangle.branch",
                    color: enabled > 0 ? .green : .secondary
                ))
            }

            if let certs = certsAny as? [[String: Any]] {
                metrics.append(ServiceMetric(label: "SSL certs", value: "\(certs.count)", icon: "lock.fill", color: .blue))

                let expiringSoon = certs.filter { cert -> Bool in
                    guard let expires = cert["expires_on"] as? String else { return false }
                    let fmt = ISO8601DateFormatter()
                    guard let date = fmt.date(from: expires) else { return false }
                    return date.timeIntervalSinceNow < 30 * 86400
                }.count
                metrics.append(ServiceMetric(
                    label: "Expiring soon",
                    value: "\(expiringSoon) cert\(expiringSoon == 1 ? "" : "s")",
                    icon: "exclamationmark.shield.fill",
                    color: expiringSoon > 0 ? .orange : .secondary,
                    isAlert: expiringSoon > 0
                ))
            }
        } catch IntegrationError.authFailed {
            await NPMTokenCache.shared.evict(for: cacheKey)
            throw IntegrationError.authFailed
        }

        return metrics
    }
}
