//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  WSFrameCollector.swift
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

protocol WSFrameCollectorDelegate: class {
    func didForm(event: WSFrameCollectorEvent)
}

public enum WSFrameCollectorEvent {
    case text(String)
    case binary(Data)
    case pong(Data?)
    case ping(Data?)
    case error(Error)
    case closed(String, WSCloseCode)
}

class WSFrameCollector {
    weak var delegate: WSFrameCollectorDelegate?
    var buffer = Data()
    var frameCount = 0
    var isText = false //was the first frame a text frame or a binary frame?
    private let queue = DispatchQueue(label: "com.vluxe.starscream.wsframer", attributes: [])

    func add(data: Data) {
        self.queue.async {
            var tempBuffer = Data()
            tempBuffer.append(data)
            while(true) {
                switch Self.process(tempBuffer) {
                case .processedFrame(let frame, let split):
                    self.add(frame: frame)
                    if split < tempBuffer.count {
                        tempBuffer = tempBuffer.advanced(by: split)
                    } else {
                        return
                    }
                case .failed(let error):
                    self.delegate?.didForm(event: .error(error))
                    return
                case .needsMoreData:
                    return
                }
            }
        }
    }

    private static func process(_ buffer: Data) -> WSFrameEvent {
        guard buffer.count > 1 else { return .needsMoreData }

        var pointer = [UInt8]()
        buffer.withUnsafeBytes { pointer.append(contentsOf: $0) }

        let opcodeRawValue = (OpCodeMask & pointer[0])
        guard let opcode = WSFrameOpCode(rawValue: opcodeRawValue) else {
            return .failed(WSError(type: .frameParseError, message: "unknown opcode: \(opcodeRawValue)", code: .protocolError))
        }

        let isMasked = (MaskMask & pointer[1])
        let RSV1 = (RSVMask & pointer[0])
        let isMaskedAndRSV = (isMasked > 0 || RSV1 > 0) && opcode != .pong
        guard !isMaskedAndRSV else {
            return .failed(WSError(type: .frameParseError, message: "masked and rsv data is not currently supported", code: .protocolError))
        }

        let isFin = (FinMask & pointer[0])
        let isControlFrame = (opcode == .connectionClose || opcode == .ping)
        guard !isControlFrame || isFin != 0 else {
            return .failed(WSError(type: .frameParseError, message: "control frames can't be fragmented", code: .protocolError))
        }

        let payloadLen = (PayloadLenMask & pointer[1])
        guard !isControlFrame || payloadLen <= 125 else {
            return .failed(WSError(type: .frameParseError, message: "payload length is longer than allowed for a control frame", code: .protocolError))
        }

        var offset = 2
        var dataLength = UInt64(payloadLen)
        var closeCode = WSCloseCode.normal
        if opcode == .connectionClose {
            if payloadLen == 1 {
                closeCode = .protocolError
                dataLength = 0
            } else if payloadLen > 1 {
                if pointer.count < 4 {
                    return .needsMoreData
                }
                let closeCodeValue = pointer.readUint16(offset: offset)
                closeCode = WSCloseCode(rawValue: closeCodeValue) ?? .protocolError

                let size = MemoryLayout<UInt16>.size
                offset += size
                dataLength -= UInt64(size)
            }
        }

        if payloadLen == 127 {
            let size = MemoryLayout<UInt64>.size
            if size + offset > pointer.count {
                return .needsMoreData
            }
            dataLength = pointer.readUint64(offset: offset)
            offset += size
        } else if payloadLen == 126 {
            let size = MemoryLayout<UInt16>.size
            if size + offset > pointer.count {
                return .needsMoreData
            }
            dataLength = UInt64(pointer.readUint16(offset: offset))
            offset += size
        }

        if dataLength > (pointer.count - offset) {
            return .needsMoreData
        }

        //I don't like this cast, but Data's count returns an Int.
        //Might be a problem with huge payloads. Need to revisit.
        let readDataLength = Int(dataLength)

        let payload: Data
        if readDataLength == 0 {
            payload = Data()
        } else {
            let end = offset + readDataLength
            payload = Data(pointer[offset..<end])
        }
        offset += readDataLength

        let frame = WSFrame(isFin: isFin > 0, isMasked: isMasked > 0, opcode: opcode, payloadLength: dataLength, payload: payload, closeCode: closeCode)
        return .processedFrame(frame: frame, offset: offset)
    }
    
    private func add(frame: WSFrame) {
        //check single frame action and out of order frames
        if frame.opcode == .connectionClose {
            var code = frame.closeCode
            var reason = "connection closed by server"
            if let customCloseReason = String(data: frame.payload, encoding: .utf8) {
                reason = customCloseReason
            } else {
                code = .protocolError
            }
            self.delegate?.didForm(event: .closed(reason, code))
            return
        } else if frame.opcode == .pong {
            self.delegate?.didForm(event: .pong(frame.payload))
            return
        } else if frame.opcode == .ping {
            self.delegate?.didForm(event: .ping(frame.payload))
            return
        } else if frame.opcode == .continueFrame && self.frameCount == 0 {
            self.delegate?.didForm(event: .error(WSError(type: .frameParseError, message: "first frame can't be a continue frame", code: .protocolError)))
            self.reset()
            return
        } else if self.frameCount > 0 && frame.opcode != .continueFrame {
            self.delegate?.didForm(event: .error(WSError(type: .frameParseError, message: "second and beyond of fragment message must be a continue frame", code: .protocolError)))
            self.reset()
            return
        }
        if self.frameCount == 0 {
            self.isText = frame.opcode == .textFrame
        }

        self.buffer.append(frame.payload)
        self.frameCount += 1
        if self.isText {
            if String(data: self.buffer, encoding: .utf8) == nil {
                self.delegate?.didForm(event: .error(WSError(type: .frameParseError, message: "not valid UTF-8 data", code: .protocolError)))
                self.reset()
                return
            }
        }
        
        if frame.isFin {
            if self.isText {
                let string = String(data: self.buffer, encoding: .utf8) ?? ""
                self.delegate?.didForm(event: .text(string))
            } else {
                self.delegate?.didForm(event: .binary(self.buffer))
            }
            self.reset()
        }
    }
    
    func reset() {
        self.buffer = Data()
        self.frameCount = 0
    }
}

/// ================================================================================================================================

let FinMask: UInt8          = 0x80
let OpCodeMask: UInt8       = 0x0F
let RSVMask: UInt8          = 0x70
let RSV1Mask: UInt8         = 0x40
let MaskMask: UInt8         = 0x80
let PayloadLenMask: UInt8   = 0x7F
let MaxFrameSize: Int       = 32


/// Standard WebSocket close codes Try to mimic URLSessionWebSocketTask.WSCloseCode here
/// For more information about the different close codes, see https://developer.mozilla.org/en-US/docs/Web/API/CloseEvent
public enum WSCloseCode: UInt16 {
    case invalid                    = 0
    case normal                     = 1000
    case goingAway                  = 1001
    case protocolError              = 1002
    case unsupportedData            = 1003
    // 1004 is reserved
    case noStatusReceived           = 1005
    case abnormalClosure            = 1006
    case invalidFramePayloadData    = 1007
    case policyViolated             = 1008
    case messageTooBig              = 1009
    case mandatoryExtensionMissing  = 1010
    case internalServerError        = 1011
    case tlsHandshakeFailure        = 1015
}

public enum WSFrameOpCode: UInt8 {
    case continueFrame = 0x0
    case textFrame = 0x1
    case binaryFrame = 0x2
    // 3-7 are reserved.
    case connectionClose = 0x8
    case ping = 0x9
    case pong = 0xA
    // B-F reserved.
}

public struct WSFrame {
    let isFin: Bool
    let isMasked: Bool
    let opcode: WSFrameOpCode
    let payloadLength: UInt64
    let payload: Data
    let closeCode: WSCloseCode //only used by connectionClose opcode
}

public enum WSFrameEvent {
    case needsMoreData
    case processedFrame(frame: WSFrame, offset: Int)
    case failed(Error)
}

class WSFramer {
    static func createWriteFrame(opcode: WSFrameOpCode, payload: Data) -> Data {
        let payloadLength = payload.count

        let capacity = payloadLength + MaxFrameSize
        var pointer = [UInt8](repeating: 0, count: capacity)

        //set the framing info
        pointer[0] = FinMask | opcode.rawValue

        var offset = 2 //skip pass the framing info
        if payloadLength < 126 {
            pointer[1] = UInt8(payloadLength)
        } else if payloadLength <= Int(UInt16.max) {
            pointer[1] = 126
            pointer.writeUInt16(UInt16(payloadLength), offset: offset)
            offset += MemoryLayout<UInt16>.size
        } else {
            pointer[1] = 127
            pointer.writeUint64(UInt64(payloadLength), offset: offset)
            offset += MemoryLayout<UInt64>.size
        }

        //clients are required to mask the payload data, but server don't according to the RFC
        pointer[1] |= MaskMask

        //write the random mask key in
        let maskKey = UInt32.random(in: 0...UInt32.max)

        pointer.writeUint32(maskKey, offset: offset)
        let maskStart = offset
        offset += MemoryLayout<UInt32>.size

        //now write the payload data in
        for i in 0..<payloadLength {
            pointer[offset] = payload[i] ^ pointer[maskStart + (i % MemoryLayout<UInt32>.size)]
            offset += 1
        }
        return Data(pointer[0..<offset])
    }
}

/// MARK: - functions for simpler array buffer reading and writing
public extension Array where Element == UInt8 {
    /// Read a UInt16 from a buffer.
    /// - Parameter offset: The offset index to start the read from (e.g. buffer[0], buffer[1], etc).
    /// - Returns: A UInt16 of the value from the buffer
    func readUint16(offset: Int) -> UInt16 {
        return (UInt16(self[offset + 0]) << 8) | UInt16(self[offset + 1])
    }

    /// Read a UInt64 from a buffer.
    /// - Parameter offset: The offset index to start the read from (e.g. buffer[0], buffer[1], etc).
    /// - Returns: A UInt64 of the value from the buffer
    func readUint64(offset: Int) -> UInt64 {
        var value = UInt64(0)
        for i in 0...7 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        return value
    }

    func unmaskData(maskStart: Int, offset: Int, length: Int) -> Data {
        var unmaskedBytes = [UInt8](repeating: 0, count: length)
        let maskSize = MemoryLayout<UInt32>.size
        for i in 0..<length {
            unmaskedBytes[i] = UInt8(self[offset + i] ^ self[maskStart + (i % maskSize)])
        }
        return Data(unmaskedBytes)
    }

    /// Writes a UInt16 to the buffer. It fills the 2 array "slots" of the UInt8 array.
    /// - Parameters:
    ///   - value: TThe value to write
    ///   - offset: The offset index to start the write from (e.g. buffer[0], buffer[1], etc).
    mutating func writeUInt16(_ value: UInt16, offset: Int) {
        self[offset + 0] = UInt8(value >> 8)
        self[offset + 1] = UInt8(value & 0xff)
    }

    /// Writes a UInt32 to the buffer. It fills the 4 array "slots" of the UInt8 array.
    /// - Parameters:
    ///   - value: The value to write
    ///   - offset: The offset index to start the write from (e.g. buffer[0], buffer[1], etc).
    mutating func writeUint32(_ value: UInt32, offset: Int) {
        for i in 0...3 {
            self[offset + i] = UInt8((value >> (8*UInt32(3 - i))) & 0xff)
        }
    }

    /// Writes a UInt64 to the buffer. It fills the 8 array "slots" of the UInt8 array.
    /// - Parameters:
    ///   - value: The value to write
    ///   - offset: The offset index to start the write from (e.g. buffer[0], buffer[1], etc).
    mutating func writeUint64(_ value: UInt64, offset: Int) {
        for i in 0...7 {
            self[offset + i] = UInt8((value >> (8*UInt64(7 - i))) & 0xff)
        }
    }
}

