//
//  WSEngine.swift
//  Starscream
//
//  Created by Dalton Cherry on 6/15/19.
//  Copyright © 2019 Vluxe. All rights reserved.
//

import Foundation
import CommonCrypto
import Network

public enum WSConnectionState: Equatable {
    case connected(headers: [String: String])
    case disconnected(closeCode: WSCloseCode = .normal, reason: String? = nil, error: WSError? = nil)

    public var isConnected: Bool {
        switch self {
        case .connected:
            return true
        case .disconnected:
            return false
        }
    }

    public static func == (lhs: WSConnectionState, rhs: WSConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.connected(let lhsHeaders), .connected(let rhsHeaders)):
            return lhsHeaders == rhsHeaders
        case (.disconnected(let lhsCloseCode, let lhsReason, let lhsError), .disconnected(let rhsCloseCode, let rhsReason, let rhsError)):
            return lhsCloseCode == rhsCloseCode && lhsReason == rhsReason && lhsError == rhsError
        default:
            return false
        }
    }
}

public protocol WSClientDelegate: class {
    func wsClient(_ client: WSClient, connectionStateChangedTo state: WSConnectionState)
    func wsClient(_ client: WSClient, viabilityChangedTo isViable: Bool)
    func wsClient(_ client: WSClient, betterPathAvailableChangedTo isBetterPathAvailable: Bool)
    func wsClient(_ client: WSClient, didReceive message: WSMessage)
}

public enum WSMessage {
    case text(String)
    case binary(Data)
    case pong(Data?)
    case ping(Data?)
}

public enum WSErrorType {
    case securityErrorAcceptFailed
    case frameParseError
}

public struct WSError: Error, Equatable {
    public let type: WSErrorType
    public let message: String
    public let code: WSCloseCode

    public init(type: WSErrorType, message: String, code: WSCloseCode) {
        self.type = type
        self.message = message
        self.code = code
    }
}

public class WSClient {
    private let websocketConnection = WSConnection()
    private let httpHandler = WSHTTPHandler()
    public var request: URLRequest
    
    private let frameHandler = WSFrameCollector()
    private var secKeyValue = ""
    private let writeQueue = DispatchQueue(label: "com.vluxe.starscream.writequeue")
    private let mutex = DispatchSemaphore(value: 1)

    private var connectionState = WSConnectionState.disconnected() {
        didSet {
            guard oldValue != self.connectionState else { return }
            self.broadcastConnectionStateChanged(to: self.connectionState)
        }
    }
    private var isViable = false {
        didSet {
            guard oldValue != self.isViable else { return }
            self.broadcastViabilityChanged(to: self.isViable)
        }
    }
    private var isBetterPathAvailable = false {
        didSet {
            guard oldValue != self.isBetterPathAvailable else { return }
            self.broadcastBetterPathAvailableChanged(to: self.isBetterPathAvailable)
        }
    }

    private var _unsafeDidUpgrade = false
    private var didUpgrade: Bool {
        get {
            self.mutex.wait()
            let value = self._unsafeDidUpgrade
            self.mutex.signal()
            return value
        }
        set {
            self.mutex.wait()
            self._unsafeDidUpgrade = newValue
            self.mutex.signal()
        }
    }

    private var _unsafeIsConnected = false
    private var isConnected: Bool {
        get {
            self.mutex.wait()
            let value = self._unsafeIsConnected
            self.mutex.signal()
            return value
        }
        set {
            self.mutex.wait()
            self._unsafeIsConnected = newValue
            self.mutex.signal()
        }
    }
    
    public weak var delegate: WSClientDelegate?

    public init(request: URLRequest) {
        self.request = request
        self.frameHandler.delegate = self
    }

    public func connect() {
        guard !self.isConnected else { return }

        self.websocketConnection.delegate = self
        self.httpHandler.delegate = self
        guard let url = request.url else {
            return
        }
        self.websocketConnection.connect(url: url, timeout: request.timeoutInterval)
    }

    public func broadcastDisconnection(closeCode: WSCloseCode = .normal, reason: String? = nil, error: WSError? = nil) {
        let capacity = MemoryLayout<UInt16>.size
        var pointer = [UInt8](repeating: 0, count: capacity)
        pointer.writeUInt16(closeCode.rawValue, offset: 0)
        let payload = Data(bytes: pointer, count: MemoryLayout<UInt16>.size)
        self.write(data: payload, opcode: .connectionClose) { [weak self] _ in
            guard let self = self else { return }
            self.disconnect(closeCode: closeCode, reason: "", error: nil)
        }
    }
    
    public func forceDisconnect() {
        self.disconnect(closeCode: WSCloseCode.abnormalClosure, reason: "Force Stopped", error: nil)
    }

    private func disconnect(closeCode: WSCloseCode, reason: String?, error: WSError?) {
        self.isConnected = false
        self.didUpgrade = false

        self.websocketConnection.disconnect()
        self.connectionState = .disconnected(closeCode: closeCode, reason: reason, error: error)
    }
    
    public func write(string: String, completion: ((Result<Void, Error>) -> Void)?) {
        guard let data = string.data(using: .utf8) else {
            completion?(.failure(WSError(type: .frameParseError, message: "Unable to convert string to utf8 data", code: .protocolError)))
            return
        }

        self.write(data: data, opcode: .textFrame) { result in
            completion?(result)
        }
    }

    public func write(data: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        self.write(data: data, opcode: .binaryFrame, completion: completion)
    }

    public func write(stringData: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        self.write(data: stringData, opcode: .textFrame, completion: completion)
    }

    public func write(ping: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        self.write(data: ping, opcode: .ping, completion: completion)
    }

    public func write(pong: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        self.write(data: pong, opcode: .pong, completion: completion)
    }
    
    private func write(data: Data, opcode: WSFrameOpCode, completion: ((Result<Void, Error>) -> Void)? = nil) {
        self.writeQueue.async {
            let completionOnMainThread = { (result: Result<Void, Error>) in
                DispatchQueue.main.async {
                    completion?(result)
                }
            }

            guard self.isConnected else {
                completionOnMainThread(.failure(WSError(type: .frameParseError, message: "State of engine doesn't allow sending", code: .protocolError)))
                return
            }

            let frameData = WSFramer.createWriteFrame(opcode: opcode, payload: data)
            self.websocketConnection.write(data: frameData) { error in
                if let error = error {
                    completionOnMainThread(.failure(error))
                } else {
                    completionOnMainThread(.success(()))
                }
            }
        }
    }

    private func broadcastConnectionStateChanged(to state: WSConnectionState) {
        DispatchQueue.main.async {
            self.delegate?.wsClient(self, connectionStateChangedTo: state)
        }
    }

    private func broadcastViabilityChanged(to isViable: Bool) {
        DispatchQueue.main.async {
            self.delegate?.wsClient(self, viabilityChangedTo: isViable)
        }
    }

    private func broadcastBetterPathAvailableChanged(to isBetterPathAvailable: Bool) {
        DispatchQueue.main.async {
            self.delegate?.wsClient(self, betterPathAvailableChangedTo: isBetterPathAvailable)
        }
    }

    private func broadcastMessageReceived(_ message: WSMessage) {
        DispatchQueue.main.async {
            self.delegate?.wsClient(self, didReceive: message)
        }
    }

    private func broadcastCancelled(_ cancelled: Bool) {

    }

    private func broadcastError(_ error: Error) {
        self.broadcastDisconnection(error: error as? WSError)
    }
}
extension WSClient {
    public func validate(headers: [String: String], key: String) -> Error? {
        if let acceptKey = headers[WSHTTPHeader.acceptName] {
            let sha = "\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".sha1Base64()
            if sha != acceptKey {
                return WSError(type: .securityErrorAcceptFailed, message: "accept header doesn't match", code: .invalid)
            }
        }
        return nil
    }
}

// MARK: - WSConnectionDelegate functions
extension WSClient: WSConnectionDelegate {
    public func wsConnection(_ wsConnection: WSConnection, didUpdateConnectionState state: NWConnection.State) {
        switch state {
        case .ready:
            self.secKeyValue = WSHTTPHeader.generateWebSocketKey()
            let wsReq = WSHTTPHeader.createUpgrade(request: self.request, secKeyValue: self.secKeyValue)
            let data = self.httpHandler.convert(request: wsReq)
            self.websocketConnection.write(data: data, completion: {_ in })
        case .cancelled:
            self.broadcastCancelled(true)
        case .failed(let error):
            self.broadcastError(error)
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    public func wsConnection(_ wsConnection: WSConnection, didReceiveData data: Data) {
        if self.didUpgrade {
            self.frameHandler.add(data: data)
        } else {
            let offset = self.httpHandler.parse(data: data)
            if offset > 0 {
                let extraData = data.subdata(in: offset..<data.endIndex)
                self.frameHandler.add(data: extraData)
            }
        }
    }
    public func wsConnection(_ wsConnection: WSConnection, didUpdateViability isViable: Bool) {
        self.isViable = isViable
    }
    
    public func wsConnection(_ wsConnection: WSConnection, didUpdateBetterPath isBetterPathAvailable: Bool) {
        self.isBetterPathAvailable = isBetterPathAvailable
    }
}

// MARK: - FrameCollectorDelegate functions
extension WSClient: WSFrameCollectorDelegate {
    public func didForm(event: WSFrameCollectorEvent) {
        switch event {
        case .text(let text):
            self.broadcastMessageReceived(.text(text))
        case .binary(let data):
            self.broadcastMessageReceived(.binary(data))
        case .pong(let data):
            self.broadcastMessageReceived(.pong(data))
        case .ping(let data):
            self.broadcastMessageReceived(.ping(data))
            self.write(data: data ?? Data(), opcode: .pong)
        case .closed(let reason, let closeCode):
            self.broadcastDisconnection(closeCode: closeCode, reason: reason)
        case .error(let error):
            self.broadcastError(error)
        }
    }

    public func receivedError(_ error: Error) {
        self.broadcastError(error)
    }
}

// MARK: - FoundationHTTPHandlerDelegate functions
extension WSClient: FoundationHTTPHandlerDelegate {
    public func didReceiveHTTP(event: HTTPEvent) {
        switch event {
        case .success(let headers):
            if let error = self.validate(headers: headers, key: secKeyValue) {
                self.broadcastError(error)
                return
            }
            self.mutex.wait()
            self.didUpgrade = true
            self.isConnected = true
            self.mutex.signal()
            if let url = self.request.url {
                HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).forEach {
                    HTTPCookieStorage.shared.setCookie($0)
                }
            }
            self.connectionState = .connected(headers: headers)
        case .failure(let error):
            self.broadcastError(error)
        }
    }
}

private extension String {
    func sha1Base64() -> String {
        let data = self.data(using: .utf8)!
        let pointer = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt8] in
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
            return digest
        }
        return Data(pointer).base64EncodedString()
    }
}
