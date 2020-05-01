//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  HTTPHandler.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/24/19.
//  Copyright © 2019 Vluxe. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
import Network

public enum HTTPUpgradeError: Error {
    case notAnUpgrade(Int)
    case invalidData
}

public struct WSHTTPHeader {
    static let upgradeName        = "Upgrade"
    static let upgradeValue       = "websocket"
    static let hostName           = "Host"
    static let connectionName     = "Connection"
    static let connectionValue    = "Upgrade"
    static let protocolName       = "Sec-WebSocket-Protocol"
    static let versionName        = "Sec-WebSocket-Version"
    static let versionValue       = "13"
    static let extensionName      = "Sec-WebSocket-Extensions"
    static let keyName            = "Sec-WebSocket-Key"
    static let originName         = "Origin"
    static let acceptName         = "Sec-WebSocket-Accept"
    static let switchProtocolCode = 101
    static let defaultSSLSchemes  = ["wss", "https"]
    
    /// Creates a new URLRequest based off the source URLRequest.
    /// - Parameter request: the request to "upgrade" the WebSocket request by adding headers.
    /// - Parameter secKeyName: the security key to use in the WebSocket request. https://tools.ietf.org/html/rfc6455#section-1.3
    /// - returns: A URLRequest request to be converted to data and sent to the server.
    public static func createUpgrade(request: URLRequest, secKeyValue: String) -> URLRequest {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else {
            return request
        }
        
        var request = request
        if request.value(forHTTPHeaderField: WSHTTPHeader.originName) == nil {
            var origin = url.absoluteString
            if let hostUrl = URL (string: "/", relativeTo: url) {
                origin = hostUrl.absoluteString
                origin.remove(at: origin.index(before: origin.endIndex))
            }
            request.setValue(origin, forHTTPHeaderField: WSHTTPHeader.originName)
        }
        request.setValue(WSHTTPHeader.upgradeValue, forHTTPHeaderField: WSHTTPHeader.upgradeName)
        request.setValue(WSHTTPHeader.connectionValue, forHTTPHeaderField: WSHTTPHeader.connectionName)
        request.setValue(WSHTTPHeader.versionValue, forHTTPHeaderField: WSHTTPHeader.versionName)
        request.setValue(secKeyValue, forHTTPHeaderField: WSHTTPHeader.keyName)
        
        if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            let headers = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, val) in headers {
                request.setValue(val, forHTTPHeaderField: key)
            }
        }

        var port = NWEndpoint.Port.http
        if let scheme = components.scheme, WSHTTPHeader.defaultSSLSchemes.contains(scheme) {
            port = .https
        }

        let hostValue = request.allHTTPHeaderFields?[WSHTTPHeader.hostName] ?? "\(host):\(port.rawValue)"
        request.setValue(hostValue, forHTTPHeaderField: WSHTTPHeader.hostName)
        return request
    }
    
    // generateWebSocketKey 16 random characters between a-z and return them as a base64 string
    public static func generateWebSocketKey() -> String {
        return Data((0..<16).map{ _ in UInt8.random(in: 97...122) }).base64EncodedString()
    }
}
