//
//  BanglaTranscriber.swift
//  Mofiz
//
//  Created by Farzana Nitol on 2025-11-09.
//

import AVFoundation
import Foundation

final class BanglaTranscriber: NSObject {
    private var recorder: AVAudioRecorder?
    
    private var audioURL: URL {
        let tmp = FileManager.default.temporaryDirectory
        return tmp.appendingPathComponent("recording.m4a")
    }
    
    func requestMicPermission() async throws {
        try await withCheckedThrowingContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                ok ? cont.resume() : cont.resume(throwing: NSError(domain: "Mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]))
            }
        }
    }
    
    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        // Remove old recording if exists
        if FileManager.default.fileExists(atPath: audioURL.path) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        
        recorder = try AVAudioRecorder(url: audioURL, settings: settings)
        guard let recorder = recorder else {
            throw NSError(domain: "RecordingError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio recorder"])
        }
        
        recorder.prepareToRecord()
        let success = recorder.record()
        
        if !success {
            throw NSError(domain: "RecordingError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"])
        }
        
        print("🎤 Recording started successfully at: \(audioURL.path)")
    }
    
    func stopRecording() {
        guard let recorder = recorder else {
            print("⚠️ No recorder to stop")
            return
        }
        
        let wasRecording = recorder.isRecording
        print("🛑 Stopping recording. Was recording: \(wasRecording)")
        
        recorder.stop()
        
        // Give the recorder more time to flush the file (300-500ms recommended)
        // The file might not be immediately available after stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Check if file exists and has content
            if FileManager.default.fileExists(atPath: self.audioURL.path) {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: self.audioURL.path),
                   let fileSize = attributes[.size] as? Int64 {
                    print("📁 Recording file size: \(fileSize) bytes")
                    if fileSize == 0 {
                        print("⚠️ Warning: Recording file is empty!")
                    }
                }
            } else {
                print("⚠️ Warning: Recording file does not exist at \(self.audioURL.path)")
            }
        }
        
        self.recorder = nil
    }
    
    func transcribeBangla() async throws -> String {
        // Check if file exists
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw NSError(domain: "TranscriptionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recording file found. Please record audio first."])
        }
        
        // Check file size
        let fileData: Data
        do {
            fileData = try Data(contentsOf: audioURL)
        } catch {
            throw NSError(domain: "TranscriptionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read recording file: \(error.localizedDescription)"])
        }
        
        guard fileData.count > 0 else {
            throw NSError(domain: "TranscriptionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Recording file is empty. Please record audio first."])
        }
        
        print("📤 Preparing to upload \(fileData.count) bytes for transcription...")
        
        let url = URL(string: "https://raspy-shape-7861.tahseen-adit.workers.dev/")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        
        // Build multipart/form-data
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        
        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        
        func appendFileField(name: String, filename: String, mime: String, data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        // Add file first, then language parameter
        // Use "audio/m4a" MIME type (more compatible than "audio/mp4")
        appendFileField(name: "file", filename: "audio.m4a", mime: "audio/m4a", data: fileData)
        appendFormField(name: "language", value: "bn") // Bengali language hint
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        print("📦 Multipart body size: \(body.count) bytes")
        print("   Boundary: \(boundary)")
        
        req.httpBody = body
        
        print("📤 Uploading audio file for Bengali transcription...")
        print("   File size: \(fileData.count) bytes")
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "WorkerError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server"])
        }
        
        guard http.statusCode == 200 else {
            let statusCode = http.statusCode
            print("❌ Transcription failed with status code: \(statusCode)")
            
            // Try to get error message from response body
            var errorMessage = "Transcription failed with status code: \(statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    errorMessage = error
                } else if let message = json["message"] as? String {
                    errorMessage = message
                }
                print("   Error response: \(json)")
            } else if let responseString = String(data: data, encoding: .utf8) {
                print("   Response body: \(responseString)")
            }
            
            throw NSError(domain: "WorkerError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        
        // Parse response - try different formats
        struct Transcription: Decodable {
            let text: String?
            let raw: RawResponse?
        }
        
        struct RawResponse: Decodable {
            let output: [OutputItem]?
        }
        
        struct OutputItem: Decodable {
            let content: [ContentItem]?
        }
        
        struct ContentItem: Decodable {
            let text: String?
        }
        
        do {
            let result = try JSONDecoder().decode(Transcription.self, from: data)
            
            // First try the direct text field
            if let text = result.text, !text.isEmpty {
                print("✅ Got transcription from 'text' field: \(text)")
                return text
            }
            
            // Try to extract from raw.output[0].content[0].text
            if let raw = result.raw,
               let output = raw.output,
               let firstOutput = output.first,
               let content = firstOutput.content,
               let firstContent = content.first,
               let text = firstContent.text,
               !text.isEmpty {
                print("✅ Got transcription from raw.output[0].content[0].text: \(text)")
                return text
            }
            
            // Try manual JSON parsing as fallback
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let raw = json["raw"] as? [String: Any],
                   let output = raw["output"] as? [[String: Any]],
                   let firstOutput = output.first,
                   let content = firstOutput["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let text = firstContent["text"] as? String,
                   !text.isEmpty {
                    print("✅ Got transcription from fallback JSON parsing: \(text)")
                    return text
                }
            }
            
            print("⚠️ No text found in transcription response")
            return ""
        } catch {
            print("❌ Decoding error: \(error)")
            // Try to get error message from response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = json["error"] as? String {
                throw NSError(domain: "WorkerError", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            throw error
        }
    }
}

