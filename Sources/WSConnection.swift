
import Foundation
import Network

public protocol WSConnectionDelegate: class {
    func wsConnection(_ wsConnection: WSConnection, didUpdateConnectionState state: NWConnection.State)
    func wsConnection(_ wsConnection: WSConnection, didUpdateViability isViable: Bool)
    func wsConnection(_ wsConnection: WSConnection, didUpdateBetterPath isBetterPathAvailable: Bool)
    func wsConnection(_ wsConnection: WSConnection, didReceiveData data: Data)
}

public enum WSConnectionError: Error {
    case invalidRequest
}

public class WSConnection {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.vluxe.starscream.networkstream", attributes: [])
    weak var delegate: WSConnectionDelegate?
    private var isRunning = false
    
    public func connect(url: URL, timeout: Double = 10) {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host else {
            //TODO: Fix
//            self.delegate?.wsConnection(self, didUpdateConnectionState: .failed(NWError.))
            return
        }


        var port: NWEndpoint.Port?
        if let urlPort = url.port {
            port = NWEndpoint.Port(integerLiteral: UInt16(urlPort))
        }

        var tlsOptions: NWProtocolTLS.Options?
        if let scheme = url.scheme, WSHTTPHeader.defaultSSLSchemes.contains(scheme) {
            port = port ?? .https
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                var error: CFError?
                if SecTrustEvaluateWithError(trust, &error) {
                    sec_protocol_verify_complete(true)
                } else {
                    sec_protocol_verify_complete(false)
                }
            }, self.queue)
            tlsOptions = options
        }

        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout)

        let parameters = NWParameters(tls: tlsOptions, tcp: options)
        self.connection = NWConnection(host: .name(host, nil), port: port ?? .http, using: parameters)
        self.start()
    }
    
    public func disconnect() {
        self.isRunning = false
        self.connection?.cancel()
    }
    
    public func write(data: Data, completion: @escaping ((Error?) -> ())) {
        self.connection?.send(content: data, completion: .contentProcessed { (error) in
            completion(error)
        })
    }

    /// Starts the connection
    private func start() {
        guard let connection = self.connection else { return }

        connection.stateUpdateHandler = self.stateUpdateHandler
        connection.viabilityUpdateHandler = self.viabilityUpdateHandler
        connection.betterPathUpdateHandler = self.betterPathUpdateHandler
        
        connection.start(queue: queue)

        self.isRunning = true
        self.readLoop()
    }

    /// Handler for when the state of the connection changes
    /// - Parameter state: The new state of the connection
    private func stateUpdateHandler(_ state: NWConnection.State) {
        self.delegate?.wsConnection(self, didUpdateConnectionState: state)
    }

    /// Handler for when the viability of the connection changes
    /// - Parameter isViable: Whether or not the connection is viable
    private func viabilityUpdateHandler(_ isViable: Bool) {
        self.delegate?.wsConnection(self, didUpdateViability: isViable)
    }

    /// Handler for when there is a better path for the connection detected
    /// - Parameter isViable: Whether or not there is a better path available for the connection
    private func betterPathUpdateHandler(_ isBetterPathAvailable: Bool) {
        self.delegate?.wsConnection(self, didUpdateBetterPath: isBetterPathAvailable)
    }
    
    //readLoop keeps reading from the connection to get the latest content
    private func readLoop() {
        guard self.isRunning, let connection = self.connection else { return }
        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096, completion: { [weak self] data, context, isComplete, error in
            guard let self = self else {return}
            if let data = data {
                self.delegate?.wsConnection(self, didReceiveData: data)
            }
            self.readLoop()
        })
    }
}

public struct URLParts {
    let port: Int
    let host: String
    let isTLS: Bool
}

public extension URL {
    /// isTLSScheme returns true if the scheme is https or wss
    var isTLSScheme: Bool {
        return true
    }

    /// getParts pulls host and port from the url.
    func getParts() -> URLParts? {
        guard let host = self.host else {
            return nil // no host, this isn't a valid url
        }
        let isTLS = isTLSScheme
        var port = self.port ?? 0
        if self.port == nil {
            if isTLS {
                port = 443
            } else {
                port = 80
            }
        }
        return URLParts(port: port, host: host, isTLS: isTLS)
    }
}
