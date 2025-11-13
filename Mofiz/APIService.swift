//
//  APIService.swift
//  Mofiz
//
//  Created by Farzana Nitol on 2025-11-09.
//

import Foundation
import AVFoundation

// Request/Response models for the Worker API
struct AskPayload: Codable {
    let prompt: String
    let model: String?
    let stream: Bool?
    let prompt_id: String?
}

struct AskResponse: Codable {
    let text: String
    let raw: RawResponse?
}

struct RawResponse: Codable {
    let output: [OutputItem]?
}

struct OutputItem: Codable {
    let content: [ContentItem]?
}

struct ContentItem: Codable {
    let type: String?
    let text: String?
}

enum APIError: Error {
    case badStatus(Int)
    case decoding
    case invalidURL
    case encoding
}

class APIService: ObservableObject {
    @Published var isLoading = false
    @Published var lastResponse: String?
    @Published var errorMessage: String?
    @Published var lastSentCommand: String?
    @Published var statusMessage: String = ""
    @Published var isSpeaking = false
    
    // Cloudflare Worker endpoint
    private let workerURL = "https://raspy-shape-7861.tahseen-adit.workers.dev/"
    
    // Text-to-speech synthesizer
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?
    private var isInterrupting = false // Track if we're interrupting
    
    // Database service
    private let databaseService: DatabaseService
    
    init(databaseService: DatabaseService = DatabaseService()) {
        self.databaseService = databaseService
        checkAvailableVoices()
    }
    
    // Check and log available voices for Bengali and English
    private func checkAvailableVoices() {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let bengaliVoices = allVoices.filter { $0.language.hasPrefix("bn") }
        let englishVoices = allVoices.filter { $0.language.hasPrefix("en") }
        
        print("🔊 Available voices check:")
        print("   Bengali voices: \(bengaliVoices.map { $0.language })")
        print("   English voices: \(englishVoices.prefix(3).map { $0.language })")
        
        if bengaliVoices.isEmpty {
            print("⚠️ No Bengali TTS voices available on this device")
            print("   To enable Bengali TTS:")
            print("   1. Go to Settings > Accessibility > Spoken Content > Voices")
            print("   2. Add Bengali voices (if available)")
            print("   Note: Bengali TTS may require iOS language packs")
        }
    }
    
    func sendCommand(_ command: String, isInterruption: Bool = false) {
        // Store the command being sent
        lastSentCommand = command
        isLoading = true
        errorMessage = nil
        lastResponse = nil
        statusMessage = "Sending to OpenAI agent..."
        
        // Log to console for debugging
        print("📤 Sending command to Worker: \(command)")
        if isInterruption {
            print("⚠️ This is an interruption - will include conversation history")
        }
        print("🌐 Worker URL: \(workerURL)")
        
        // Use async/await for cleaner code
        Task {
            do {
                // Get conversation context with exponential backoff
                let contextPrompt = await buildContextPrompt(userMessage: command, isInterruption: isInterruption)
                
                let response = try await askViaWorker(prompt: contextPrompt)
                await MainActor.run {
                    self.isLoading = false
                    self.lastResponse = response
                    self.statusMessage = "Response received"
                    print("✅ Response received: \(response)")
                    
                    // Save to database (save the user's command, not the full context)
                    self.saveChatToDatabase(message: command, response: response)
                    
                    // Convert response to speech and play it
                    self.speakText(response)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.statusMessage = "Error occurred"
                    
                    if let apiError = error as? APIError {
                        switch apiError {
                        case .badStatus(let status):
                            self.errorMessage = "Server error: HTTP \(status)"
                            print("❌ Server error: HTTP \(status)")
                        case .decoding:
                            self.errorMessage = "Failed to decode response"
                            print("❌ Decoding error")
                        case .invalidURL:
                            self.errorMessage = "Invalid URL"
                            print("❌ Invalid URL")
                        case .encoding:
                            self.errorMessage = "Failed to encode request"
                            print("❌ Encoding error")
                        }
                    } else {
                        self.errorMessage = "Error: \(error.localizedDescription)"
                        print("❌ Error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    // Non-streaming call to the Worker
    private func askViaWorker(prompt: String) async throws -> String {
        guard let url = URL(string: workerURL) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Create payload - using gpt-4o-mini as default, non-streaming
        let payload = AskPayload(
            prompt: prompt,
            model: "gpt-4o-mini",
            stream: false,
            prompt_id: nil
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw APIError.encoding
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        
        print("📥 Response status code: \(status)")
        
        guard status == 200 else {
            // Try to extract error message from response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = json["error"] as? [String: Any],
               let message = errorMessage["message"] as? String {
                print("❌ API Error: \(message)")
                throw APIError.badStatus(status)
            } else {
                throw APIError.badStatus(status)
            }
        }
        
        do {
            let decoded = try JSONDecoder().decode(AskResponse.self, from: data)
            
            // First try the direct text field
            if !decoded.text.isEmpty {
                print("✅ Got text from 'text' field: \(decoded.text)")
                return decoded.text
            }
            
            // If text is empty, try to extract from raw.output[0].content[0].text
            if let raw = decoded.raw,
               let output = raw.output,
               let firstOutput = output.first,
               let content = firstOutput.content,
               let firstContent = content.first,
               let text = firstContent.text,
               !text.isEmpty {
                print("✅ Got text from raw.output[0].content[0].text: \(text)")
                return text
            }
            
            // If still no text, try parsing as dictionary to find text anywhere
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Try raw.output[0].content[0].text path
                if let raw = json["raw"] as? [String: Any],
                   let output = raw["output"] as? [[String: Any]],
                   let firstOutput = output.first,
                   let content = firstOutput["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let text = firstContent["text"] as? String,
                   !text.isEmpty {
                    print("✅ Got text from JSON parsing: \(text)")
                    return text
                }
            }
            
            print("⚠️ No text found in response")
            throw APIError.decoding
        } catch {
            print("❌ Decoding error: \(error)")
            // Try one more time with manual JSON parsing
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let raw = json["raw"] as? [String: Any],
                   let output = raw["output"] as? [[String: Any]],
                   let firstOutput = output.first,
                   let content = firstOutput["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let text = firstContent["text"] as? String,
                   !text.isEmpty {
                    print("✅ Got text from fallback JSON parsing: \(text)")
                    return text
                }
            }
            throw APIError.decoding
        }
    }
    
    // Detect if text contains Bengali characters
    private func containsBengali(_ text: String) -> Bool {
        return text.unicodeScalars.contains { scalar in
            (0x0980...0x09FF).contains(scalar.value) // Bengali Unicode range
        }
    }
    
    // Convert text to speech and play it
    func speakText(_ text: String) {
        // Stop any ongoing speech
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        
        // Configure audio session for playback with mixing support
        // This allows simultaneous recording during playback
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Use .playAndRecord to allow simultaneous recording
            // Use .mixWithOthers to allow mixing with other audio
            // DON'T use .defaultToSpeaker - without it, defaults to earpiece/receiver to avoid feedback
            // This prevents microphone from picking up TTS audio from speaker
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth, .mixWithOthers])
            
            // Without .defaultToSpeaker, audio will play through earpiece/receiver by default
            // This prevents feedback loop where microphone picks up speaker audio
            
            // Activate without deactivating first - this is safe with .mixWithOthers
            try audioSession.setActive(true, options: [])
            print("✅ Audio session configured for TTS with earpiece output (to avoid feedback)")
        } catch {
            print("❌ Error setting up audio session for speech: \(error.localizedDescription)")
            // Continue anyway - might still work
        }
        
        // Create speech utterance
        let utterance = AVSpeechUtterance(string: text)
        
        // Detect language and set appropriate voice
        let isBengali = containsBengali(text)
        
        if isBengali {
            // Try to get Bengali voice
            if let bengaliVoice = AVSpeechSynthesisVoice(language: "bn-BD") {
                utterance.voice = bengaliVoice
                print("🔊 Using Bengali (BD) voice")
            } else if let bengaliVoice = AVSpeechSynthesisVoice(language: "bn-IN") {
                utterance.voice = bengaliVoice
                print("🔊 Using Bengali (IN) voice")
            } else {
                // Check what Bengali voices are available
                let availableVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("bn") }
                print("📋 Available Bengali voices: \(availableVoices.map { $0.language })")
                
                if let firstBengaliVoice = availableVoices.first {
                    utterance.voice = firstBengaliVoice
                    print("🔊 Using available Bengali voice: \(firstBengaliVoice.language)")
                } else {
                    // Fallback to system default (might not work for Bengali)
                    print("⚠️ No Bengali voice available, using default")
                    utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.languageCode ?? "en-US")
                }
            }
            utterance.rate = 0.45 // Slightly slower for Bengali
        } else {
            // Use system default English voice (the one selected in Settings)
            // Try to get the preferred language voice first
            let preferredLanguage = Locale.preferredLanguages.first ?? "en"
            if let preferredVoice = AVSpeechSynthesisVoice(language: preferredLanguage) {
                utterance.voice = preferredVoice
                print("🔊 Using preferred language voice: \(preferredLanguage)")
            } else if let defaultVoice = AVSpeechSynthesisVoice(language: Locale.current.languageCode ?? "en") {
                utterance.voice = defaultVoice
                print("🔊 Using system default voice: \(Locale.current.languageCode ?? "en")")
            } else {
                // Fallback to any English voice
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                print("🔊 Using fallback English (US) voice")
            }
            utterance.rate = 0.5 // Normal rate for English
        }
        
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Reset interruption flag when starting new speech
        isInterrupting = false
        
        // Set delegate to track when speaking finishes
        speechDelegate = SpeechDelegate { [weak self] finished in
            DispatchQueue.main.async {
                self?.isSpeaking = false
                if finished {
                    print("✅ Finished speaking response")
                    // Only notify if we actually finished naturally (not interrupted)
                    if !(self?.isInterrupting ?? false) {
                        // Speech finished naturally - switch back to speaker
                        do {
                            let audioSession = AVAudioSession.sharedInstance()
                            try audioSession.overrideOutputAudioPort(.speaker)
                            print("🔊 Switched audio output back to speaker after TTS finished")
                        } catch {
                            print("⚠️ Could not switch audio output: \(error)")
                        }
                        // Speech finished naturally - notify
                        NotificationCenter.default.post(name: NSNotification.Name("SpeechFinished"), object: nil)
                    } else {
                        // Speech was interrupted - don't notify
                        print("🔇 Speech was interrupted - not posting SpeechFinished")
                        self?.isInterrupting = false // Reset flag
                    }
                }
            }
        }
        speechSynthesizer.delegate = speechDelegate
        
        // Start speaking
        isSpeaking = true
        speechSynthesizer.speak(utterance)
        print("🔊 Speaking response (\(isBengali ? "Bengali" : "English")): \(text.prefix(50))...")
        
        // Notify that we're starting to speak (so UI can start listening for interruptions)
        // Include timestamp in notification for debouncing
        NotificationCenter.default.post(
            name: NSNotification.Name("SpeechStarted"), 
            object: nil,
            userInfo: ["timestamp": Date()]
        )
    }
    
    func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            // Mark that we're interrupting
            isInterrupting = true
            
            // Stop speaking
            speechSynthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
            
            // Switch back to speaker for normal listening (when not during playback)
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.overrideOutputAudioPort(.speaker)
                print("🔇 Switched audio output back to speaker after interruption")
            } catch {
                print("⚠️ Could not switch audio output: \(error)")
            }
            
            // Don't deactivate audio session - speech recognition might be using it
            // The session will be managed by SpeechRecognitionManager
            // Don't post SpeechFinished notification - we want recognition to continue
            print("🔇 Stopped speaking (interrupted) - audio session remains active for recording")
            print("🔇 Recognition should continue - not posting SpeechFinished notification")
        }
    }
    
    // MARK: - Conversation Context Management
    
    /// Build context prompt with conversation history using exponential backoff
    private func buildContextPrompt(userMessage: String, isInterruption: Bool) async -> String {
        let user = databaseService.getOrCreateCurrentUser()
        guard let userId = user.id else {
            return userMessage // No user, just return the message
        }
        
        // Get active thread
        let activeThread = databaseService.getOrCreateActiveThread(for: userId)
        guard let threadId = activeThread.id else {
            return userMessage // No thread, just return the message
        }
        
        // Get conversation history from this thread
        let chatHistory = databaseService.getChatHistory(forThreadId: threadId)
        
        // If no history, just return the message
        if chatHistory.isEmpty {
            return userMessage
        }
        
        // For interruptions, always include context. For regular messages, include if there's history
        if !isInterruption && chatHistory.count == 0 {
            return userMessage
        }
        
        // Exponential backoff: include fewer messages as we go back
        // Start with most recent messages and include fewer as we go back
        var contextMessages: [(message: String, response: String)] = []
        var totalLength = userMessage.count
        let maxContextLength = 2000 // Approximate token limit consideration
        
        // Start from most recent and work backwards with exponential backoff
        var includeCount = min(5, chatHistory.count) // Start with last 5 messages
        var startIndex = max(0, chatHistory.count - includeCount)
        
        while startIndex < chatHistory.count && totalLength < maxContextLength {
            let chat = chatHistory[startIndex]
            if let message = chat.message, let response = chat.response {
                let combinedLength = message.count + response.count
                if totalLength + combinedLength > maxContextLength {
                    break // Stop if adding this would exceed limit
                }
                contextMessages.insert((message: message, response: response), at: 0)
                totalLength += combinedLength
            }
            startIndex += 1
            
            // Exponential backoff: reduce how many we include as we go back
            if startIndex >= chatHistory.count {
                break
            }
            // For older messages, include fewer (every 2nd, then every 4th, etc.)
            if startIndex > chatHistory.count - 5 {
                // First 5: include all
            } else if startIndex > chatHistory.count - 10 {
                // Next 5: include every 2nd
                if (chatHistory.count - startIndex) % 2 != 0 {
                    startIndex += 1
                    continue
                }
            } else {
                // Older: include every 4th
                if (chatHistory.count - startIndex) % 4 != 0 {
                    startIndex += 1
                    continue
                }
            }
        }
        
        // Build context string
        var contextString = ""
        for (index, chat) in contextMessages.enumerated() {
            contextString += "Previous conversation \(contextMessages.count - index):\n"
            contextString += "User: \(chat.message)\n"
            contextString += "Assistant: \(chat.response)\n\n"
        }
        
        // Combine context with new message
        if !contextString.isEmpty {
            let fullPrompt = """
            \(contextString)Current conversation:
            User: \(userMessage)
            Assistant:
            """
            print("📝 Built context with \(contextMessages.count) previous messages")
            return fullPrompt
        }
        
        return userMessage
    }
    
    // MARK: - Database Operations
    
    /// Save chat conversation to database
    private func saveChatToDatabase(message: String, response: String) {
        // Get or create current user
        let user = databaseService.getOrCreateCurrentUser()
        guard let userId = user.id else {
            print("❌ User ID is nil, cannot save chat history")
            return
        }
        
        // Detect language
        let language = containsBengali(message) || containsBengali(response) ? "bn" : "en"
        
        // Create metadata
        let metadata: [String: Any] = [
            "model": "gpt-4o-mini",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "messageLength": message.count,
            "responseLength": response.count
        ]
        
        // Save to database
        databaseService.saveChatHistory(
            userId: userId,
            message: message,
            response: response,
            language: language,
            metadata: metadata
        )
    }
    
    /// Create a new chat thread
    func createNewThread() {
        let user = databaseService.getOrCreateCurrentUser()
        guard let userId = user.id else { return }
        
        databaseService.createNewThread(for: userId, title: nil)
        print("✅ Created new thread")
    }
}

// Helper class to handle speech synthesizer delegate
class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: (Bool) -> Void
    
    init(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish(true)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish(false)
    }
}

