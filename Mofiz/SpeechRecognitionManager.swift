//
//  SpeechRecognitionManager.swift
//  Mofiz
//
//  Created by Farzana Nitol on 2025-11-09.
//

import Foundation
import Speech
import AVFoundation

class SpeechRecognitionManager: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var recognizedText = ""
    @Published var statusMessage = "Initializing..."
    @Published var wakeWordDetected = false
    @Published var isListeningDuringPlayback = false // New: track if listening during TTS
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isIntentionallyStopping = false
    
    // Interruption detection state
    private var lastInterruptionAttempt: Date?
    private var interruptionDebounceInterval: TimeInterval = 1.0 // Minimum 1 second between interruptions
    private var ttsStartTime: Date? // Track when TTS started to prevent immediate false triggers
    
    var onCommandRecognized: ((String) -> Void)?
    var onInterruptDetected: ((String) -> Void)? // New: callback when user interrupts during playback
    
    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        requestAuthorization()
    }
    
    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        DispatchQueue.main.async {
                            if granted {
                                self?.statusMessage = "Ready to listen. Say 'Hello' followed by your command."
                            } else {
                                self?.statusMessage = "Microphone permission denied"
                            }
                        }
                    }
                case .denied, .restricted, .notDetermined:
                    self?.statusMessage = "Speech recognition permission denied"
                @unknown default:
                    self?.statusMessage = "Unknown authorization status"
                }
            }
        }
    }
    
    func startListening(duringPlayback: Bool = false) {
        guard !isListening else { 
            print("⚠️ Already listening, skipping start")
            return 
        }
        
        guard let recognizer = speechRecognizer else {
            statusMessage = "Speech recognizer not available"
            return
        }
        
        guard recognizer.isAvailable else {
            statusMessage = "Speech recognizer not available"
            return
        }
        
        isListeningDuringPlayback = duringPlayback
        statusMessage = duringPlayback ? "Listening for interruption..." : "Listening..."
        
        // Only stop existing recognition if NOT during playback
        // During playback, we want to start fresh without stopping (to avoid session conflicts)
        if !duringPlayback {
            stopListening()
            // Add a small delay to ensure audio session is fully deactivated
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupAudioSession()
            }
        } else {
            // During playback, start immediately without stopping
            setupAudioSession()
        }
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Configure the audio session for recording
            // Use .playAndRecord if we're listening during playback, otherwise .record
            if isListeningDuringPlayback {
                // When listening during playback, TTS has already configured the session
                // We need to ensure it's set to .playAndRecord with proper options
                let currentCategory = audioSession.category
                if currentCategory != .playAndRecord {
                    // Reconfigure to playAndRecord if not already set
                    print("🔄 Reconfiguring audio session to .playAndRecord for simultaneous recording")
                    try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                }
                // Activate without deactivating first - this is safe with .mixWithOthers
                try audioSession.setActive(true, options: [])
                print("✅ Audio session activated for recording during playback")
            } else {
                // Normal recording mode - safe to deactivate first
                // Check if other audio is playing before deactivating
                if !audioSession.isOtherAudioPlaying {
                    try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                }
                try audioSession.setCategory(.record, mode: .measurement, options: [])
                // Activate the audio session
                try audioSession.setActive(true, options: [])
            }
            
            // Create recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            
            guard let recognitionRequest = recognitionRequest else {
                statusMessage = "Unable to create recognition request"
                return
            }
            
            recognitionRequest.shouldReportPartialResults = true
            
            // Setup audio engine
            let inputNode = audioEngine.inputNode
            
            // Stop engine if running and remove any existing tap
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            
            // Remove any existing tap before resetting
            if inputNode.numberOfInputs > 0 {
                inputNode.removeTap(onBus: 0)
            }
            
            // Reset engine to ensure clean state
            audioEngine.reset()
            
            // Get the format from the input node
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // Validate format
            let sampleRate = recordingFormat.sampleRate
            let channelCount = recordingFormat.channelCount
            
            guard sampleRate > 0 && sampleRate <= 192000, channelCount > 0 && channelCount <= 32 else {
                throw NSError(domain: "AudioSetupError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio format"])
            }
            
            // Install tap with the format
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            
            // Prepare and start the engine
            audioEngine.prepare()
            try audioEngine.start()
            
            isListening = true
            wakeWordDetected = false
            if isListeningDuringPlayback {
                statusMessage = "Listening for interruption..."
                // Reset TTS start time when we start listening during playback
                // This helps prevent false triggers from initial TTS audio
                ttsStartTime = Date()
                print("✅ Started listening for interruptions during playback")
            } else {
                statusMessage = "Listening... Say 'Hello' followed by your command, then tap Send."
                print("✅ Started listening normally")
            }
            
            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] (result: SFSpeechRecognitionResult?, error: Error?) in
                guard let self = self else { return }
                
                if let error = error {
                    let nsError = error as NSError
                    let errorDescription = error.localizedDescription.lowercased()
                    
                    // Check if this is a cancellation error (expected when stopping)
                    let isCancellation = errorDescription.contains("cancel") || errorDescription.contains("cancelled")
                    
                    // If we're intentionally stopping or it's a cancellation, don't show as error
                    if self.isIntentionallyStopping || isCancellation {
                        DispatchQueue.main.async {
                            if self.recognitionTask != nil {
                                self.recognitionTask = nil
                            }
                        }
                    } else {
                        // Real error - show it
                        DispatchQueue.main.async {
                            self.statusMessage = "Error: \(error.localizedDescription)"
                            self.stopListening()
                        }
                    }
                    return
                }
                
                if let result = result {
                    let transcribedText = result.bestTranscription.formattedString.lowercased()
                    let fullText = result.bestTranscription.formattedString
                    
                    DispatchQueue.main.async {
                        // Always update recognized text for UI display
                        self.recognizedText = fullText
                        
                        // If listening during playback and user says something, interrupt immediately
                        // Use stricter filtering to prevent false positives from TTS feedback
                        if self.isListeningDuringPlayback && !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Filter out common noise/feedback patterns
                            let lowercasedText = trimmedText.lowercased()
                            let noisePatterns = ["uh", "um", "ah", "eh", "oh", "hmm", "huh", "the", "a", "an", "is", "are", "was", "were"]
                            
                            // Check if text is just noise
                            let words = lowercasedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                            let isLikelyNoise = words.count <= 2 && words.allSatisfy { noisePatterns.contains($0) }
                            
                            // Debounce: prevent rapid false triggers
                            let now = Date()
                            if let lastAttempt = self.lastInterruptionAttempt {
                                let timeSinceLastAttempt = now.timeIntervalSince(lastAttempt)
                                if timeSinceLastAttempt < self.interruptionDebounceInterval {
                                    print("⏸️ Interruption debounced (last attempt \(String(format: "%.2f", timeSinceLastAttempt))s ago)")
                                    return // Skip this interruption attempt
                                }
                            }
                            
                            // Prevent interruptions too soon after TTS starts (likely feedback)
                            if let ttsStart = self.ttsStartTime {
                                let timeSinceTTSStart = now.timeIntervalSince(ttsStart)
                                if timeSinceTTSStart < 0.5 { // Wait at least 0.5 seconds after TTS starts
                                    print("⏸️ Too soon after TTS start (\(String(format: "%.2f", timeSinceTTSStart))s), ignoring potential feedback")
                                    return
                                }
                            }
                            
                            // Stricter requirements for interruption:
                            // 1. Must be a final result (not partial) to reduce false positives
                            // 2. Must have at least 5 characters (more than just noise)
                            // 3. Must not be just noise patterns
                            // 4. Must have at least 2 words for better confidence
                            let hasMinimumLength = trimmedText.count >= 5
                            let hasMultipleWords = words.count >= 2
                            let isNotNoise = !isLikelyNoise
                            let isFinalResult = result.isFinal
                            
                            let shouldInterrupt = isFinalResult && hasMinimumLength && hasMultipleWords && isNotNoise
                            
                            if shouldInterrupt {
                                // User is speaking during playback - trigger interruption
                                print("🔊 User interrupted during playback: \(trimmedText.prefix(50))...")
                                print("🔊 Result is final: \(result.isFinal), Words: \(words.count), Length: \(trimmedText.count)")
                                
                                // Update last interruption attempt
                                self.lastInterruptionAttempt = now
                                
                                // Cancel recognition task to stop processing
                                self.recognitionTask?.cancel()
                                self.recognitionTask = nil
                                // End audio on recognition request
                                self.recognitionRequest?.endAudio()
                                self.recognitionRequest = nil
                                // Mark as not listening (but keep session active)
                                self.isListening = false
                                // Trigger interruption callback (this will stop TTS)
                                self.onInterruptDetected?(trimmedText)
                                return // Don't check for wake word during interruption
                            }
                            // Note: We don't log filtered interruptions to avoid console spam
                            // Only log actual interruptions above
                        }
                        
                        // Check for wake word (only when not listening during playback)
                        if !self.wakeWordDetected && !self.isListeningDuringPlayback {
                            let detected = self.checkWakeWord(in: transcribedText)
                            if detected {
                                print("🔔 Wake word detected!")
                                self.wakeWordDetected = true
                                self.statusMessage = "Wake word detected! Continue speaking, then tap Send."
                            }
                        }
                    }
                }
            }
            
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Error starting audio: \(error.localizedDescription)"
            }
            stopListening()
        }
    }
    
    // Check if wake word is present in the text
    private func checkWakeWord(in text: String) -> Bool {
        let lowercasedText = text.lowercased()
        let wakeWordVariations = ["hello", "hallo", "halo"]
        
        for variation in wakeWordVariations {
            if lowercasedText.contains(variation) {
                return true
            }
        }
        
        return false
    }
    
    func stopListening() {
        // Mark that we're intentionally stopping to avoid showing cancellation errors
        isIntentionallyStopping = true
        
        // Cancel recognition task first
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // End audio on recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Stop and reset audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        // Remove tap from input node (safely)
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        // Reset audio engine
        audioEngine.reset()
        
        // Deactivate audio session (with error handling)
        // Don't deactivate if we were listening during playback - TTS might still be active
        if !isListeningDuringPlayback {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Only deactivate if we're the active session and no other audio is playing
                if audioSession.isOtherAudioPlaying {
                    // Other audio is playing, don't deactivate
                    print("ℹ️ Other audio is playing, skipping session deactivation")
                } else {
                    try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                }
            } catch {
                // Log but don't fail - session deactivation errors are often non-critical
                print("⚠️ Error deactivating audio session (non-critical): \(error.localizedDescription)")
            }
        } else {
            // When stopping during playback, just stop the engine, don't touch the session
            print("ℹ️ Stopping listening during playback - leaving audio session active for TTS")
        }
        
        isListening = false
        isListeningDuringPlayback = false
        wakeWordDetected = false
        
        // Reset the flag after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isIntentionallyStopping = false
        }
    }
    
    func clearAndStartAgain() {
        // Stop current recognition to clear the state
        stopListening()
        
        // Clear recognized text and reset
        recognizedText = ""
        wakeWordDetected = false
        
        // Wait a moment for cleanup, then start fresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.statusMessage = "Listening... Say 'Hello' followed by your command, then tap Send."
            self.startListening()
        }
    }
    
    deinit {
        stopListening()
    }
}
