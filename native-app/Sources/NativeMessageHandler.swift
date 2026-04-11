import Foundation
import Cocoa

// MARK: - NativeMessageHandler — Chrome Native Messaging Protocol

/// Chrome Native Messaging protocol implementation
/// Format: 4-byte little-endian UInt32 length prefix + UTF-8 JSON body
class NativeMessageHandler {

    var onMessage: (([String: Any]) -> Void)?

    private let inputHandle = FileHandle.standardInput
    private let outputHandle = FileHandle.standardOutput
    private var isListening = false
    private let outputQueue = DispatchQueue(label: "com.aspect.floatvideo.output")

    // MARK: - Listening

    func startListening() {
        guard !isListening else { return }
        isListening = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NSLog("[FloatVideo] Native messaging: listening for messages...")

            while self?.isListening == true {
                guard let message = self?.readMessage() else {
                    // stdin closed (Chrome disconnected), exit
                    NSLog("[FloatVideo] stdin closed, exiting...")
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                    return
                }
                self?.onMessage?(message)
            }
        }
    }

    func stopListening() {
        isListening = false
    }

    // MARK: - Read Message

    private func readMessage() -> [String: Any]? {
        // 1. Read 4-byte length prefix (little-endian UInt32)
        let lengthData = inputHandle.readData(ofLength: 4)
        guard lengthData.count == 4 else {
            return nil // EOF or error
        }

        let length: UInt32 = lengthData.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self)
        }

        guard length > 0, length < 1_048_576 else {
            NSLog("[FloatVideo] Invalid message length: \(length)")
            return nil
        }

        // 2. Read JSON message body
        var messageData = Data()
        var remaining = Int(length)

        while remaining > 0 {
            let chunk = inputHandle.readData(ofLength: remaining)
            guard chunk.count > 0 else {
                NSLog("[FloatVideo] Unexpected EOF while reading message body")
                return nil
            }
            messageData.append(chunk)
            remaining -= chunk.count
        }

        // 3. Parse JSON
        do {
            guard let json = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                NSLog("[FloatVideo] Message is not a JSON object")
                return nil
            }
            NSLog("[FloatVideo] Received message: \(json)")
            return json
        } catch {
            NSLog("[FloatVideo] JSON parse error: \(error)")
            return nil
        }
    }

    // MARK: - Send Message

    func sendMessage(_ message: [String: Any]) {
        outputQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                let jsonData = try JSONSerialization.data(withJSONObject: message)

                // 1. Write 4-byte length prefix (little-endian)
                var length = UInt32(jsonData.count)
                let lengthData = Data(bytes: &length, count: 4)

                // 2. Write JSON message body
                self.outputHandle.write(lengthData)
                self.outputHandle.write(jsonData)

                NSLog("[FloatVideo] Sent message: \(message)")
            } catch {
                NSLog("[FloatVideo] Failed to serialize message: \(error)")
            }
        }
    }
}
