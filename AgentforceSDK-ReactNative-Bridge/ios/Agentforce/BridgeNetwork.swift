/*
 * Copyright (c) 2026-present, salesforce.com, inc. All rights reserved.
 *
 * Network implementation for Agentforce DataProvider
 * Uses Mobile SDK RestClient for authenticated API calls
 * Only available when SalesforceSDKCore is present (Employee Agent builds)
 */

import Foundation
import SalesforceNetwork

#if canImport(SalesforceSDKCore)
import SalesforceSDKCore

/**
 * Network implementation that bridges SalesforceNetwork.Network interface
 * to Mobile SDK RestClient for authenticated Salesforce API calls.
 */
struct BridgeNetwork: SalesforceNetwork.Network {

    private let restClient: RestClient

    init(restClient: RestClient = RestClient.shared) {
        self.restClient = restClient
    }

    func data(for request: SalesforceNetwork.NetworkRequest) async throws -> (Data, URLResponse) {
        let restRequest = try createRestRequest(from: request)

        // The Mobile SDK's SFRestAPI presents an interactive OAuth login web view whenever the
        // current user has NEITHER an access token NOR a refresh token (SFRestAPI.m: "No auth
        // credentials found. Authenticating before sending request"). It does so on whatever
        // thread the request runs on — for Agentforce traffic that is a background queue, which
        // also violates UIKit main-thread rules — and yanks the user to a login screen
        // mid-session (e.g. right after "clear chat") instead of letting the host app run its
        // own OAuth flow. When there is nothing left to refresh with, fail fast with a clean
        // auth error so the SDK surfaces a recoverable state and the host controls
        // re-authentication. When a refresh token still exists, let the request proceed so
        // SFRestAPI can refresh the access token silently on a 401.
        // See [[project_rn_ios_auth_login_fix]].
        if restRequest.requiresAuthentication {
            let credentials = UserAccountManager.shared.currentUserAccount?.credentials
            let hasAccessToken = !(credentials?.accessToken?.isEmpty ?? true)
            let hasRefreshToken = !(credentials?.refreshToken?.isEmpty ?? true)
            if !hasAccessToken && !hasRefreshToken {
                throw NetworkError.authenticationRequired
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            restClient.send(request: restRequest) { result in
                switch result {
                case let .success(response):
                    if let data = try? response.asData() {
                        continuation.resume(returning: (data, response.urlResponse))
                    } else {
                        continuation.resume(throwing: NetworkError.noData)
                    }
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func createRestRequest(from request: NetworkRequest) throws -> RestRequest {
        let method = request.baseRequest.restRequestMethod

        guard let url = request.baseRequest.url else {
            throw NetworkError.invalidURL
        }

        // Determine path based on URL scheme
        // placeholder:// URLs are from DataProvider - extract path so RestClient prepends instance URL
        // Other URLs (https://) should be used as-is (full URL for agent session API, etc.)
        let path: String
        var queryParams: [String: String] = [:]

        if url.scheme == "placeholder" {
            path = url.path
            // Extract query parameters from the URL
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                for item in queryItems {
                    if let value = item.value {
                        queryParams[item.name] = value
                    }
                }
            }
        } else {
            path = url.absoluteString
        }

        let restRequest = RestRequest(method: method, path: path, queryParams: queryParams)

        restRequest.requiresAuthentication = request.requiresAuthentication ?? true

        if let body = request.baseRequest.httpBody {
            let contentType = request.baseRequest.value(forHTTPHeaderField: "Content-Type")
                ?? "application/json; charset=utf-8"
            restRequest.setCustomRequestBodyData(body, contentType: contentType)
        }

        // Set endpoint for paths starting with "/" so RestClient prepends instance URL
        // For full URLs (https://), don't set endpoint
        if path.starts(with: "/") {
            restRequest.endpoint = kSFDefaultRestEndpoint
        } else {
            restRequest.endpoint = ""
        }

        // Copy headers, but drop the caller's Authorization header on authenticated requests.
        // The Mobile SDK RestClient injects and — crucially — REFRESHES its own OAuth bearer
        // token. SFRestRequest.prepareRequestForSend applies our customHeaders AFTER setting the
        // Mobile SDK bearer, so a token copied here overrides the Mobile SDK's managed token on
        // every send and every 401-refresh replay, defeating silent token refresh for Agentforce
        // traffic (and pinning a stale/expired token that then fails). Let the Mobile SDK own the
        // Authorization header instead. See [[project_rn_ios_auth_login_fix]].
        if let headerFields = request.baseRequest.allHTTPHeaderFields {
            for (key, value) in headerFields {
                if restRequest.requiresAuthentication,
                   key.caseInsensitiveCompare("Authorization") == .orderedSame {
                    continue
                }
                restRequest.setHeaderValue(value, forHeaderName: key)
            }
        }

        return restRequest
    }
}

// MARK: - Extensions

private extension URLRequest {
    var restRequestMethod: RestRequest.Method {
        switch httpMethod {
        case "DELETE": return .DELETE
        case "GET": return .GET
        case "POST": return .POST
        case "PUT": return .PUT
        case "PATCH": return .PATCH
        case "HEAD": return .HEAD
        default: return .GET
        }
    }
}

enum NetworkError: Error {
    case noData
    case invalidURL
    /// The Mobile SDK has no usable session (no access token and no refresh token). Surfaced
    /// instead of letting SFRestAPI trigger an interactive login so the host app controls auth.
    case authenticationRequired
}

#endif // canImport(SalesforceSDKCore)
