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
    private var interruptionDebounceInterval: TimeInterval = 1.0 // Increased to 1.0s to prevent rapid false triggers
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
                    // DON'T use .defaultToSpeaker - without it, defaults to earpiece to avoid feedback
                    print("🔄 Reconfiguring audio session to .playAndRecord for simultaneous recording")
                    try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .mixWithOthers])
                    // Without .defaultToSpeaker, audio will use earpiece by default (avoids feedback)
                }
                // Activate without deactivating first - this is safe with .mixWithOthers
                try audioSession.setActive(true, options: [])
                
                // EXPLICITLY ensure earpiece output is maintained (don't let it switch to speaker)
                // This prevents any possibility of TTS audio going to speaker and causing feedback
                try audioSession.overrideOutputAudioPort(.none)
                print("✅ Audio session activated for recording during playback (EXPLICIT earpiece output maintained)")
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
                print("✅ Started listening for interruptions during playback (continuous recognition)")
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
                        if self.isListeningDuringPlayback {
                            // Debug: log all recognition results during playback
                            if !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                print("🎤 Recognition during playback: '\(fullText.prefix(30))...' (final: \(result.isFinal))")
                            }
                        }
                        
                        if self.isListeningDuringPlayback && !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Filter out common noise/feedback patterns and TTS-like patterns
                            let lowercasedText = trimmedText.lowercased()
                            let noisePatterns = ["uh", "um", "ah", "eh", "oh", "hmm", "huh", "the", "a", "an", "is", "are", "was", "were"]
                            
                            // Check if text is just noise (more lenient - only single noise words)
                            let words = lowercasedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                            // Only consider it noise if it's a single noise word
                            let isLikelyNoise = words.count == 1 && words.allSatisfy { noisePatterns.contains($0) }
                            
                            // Debounce: prevent rapid false triggers
                            let now = Date()
                            if let lastAttempt = self.lastInterruptionAttempt {
                                let timeSinceLastAttempt = now.timeIntervalSince(lastAttempt)
                                if timeSinceLastAttempt < self.interruptionDebounceInterval {
                                    print("⏸️ Interruption debounced (last attempt \(String(format: "%.2f", timeSinceLastAttempt))s ago)")
                                    return // Skip this interruption attempt
                                }
                            }
                            
                            // Prevent interruptions too soon after TTS starts (longer delay to avoid TTS feedback)
                            if let ttsStart = self.ttsStartTime {
                                let timeSinceTTSStart = now.timeIntervalSince(ttsStart)
                                if timeSinceTTSStart < 2.0 { // Increased to 2.0s to avoid TTS feedback
                                    print("⏸️ Too soon after TTS start (\(String(format: "%.2f", timeSinceTTSStart))s), ignoring potential TTS feedback")
                                    return
                                }
                            }
                            
                            // Balanced Requirements for interruption to avoid TTS feedback but allow real interruptions:
                            // 1. Must have at least 2 words (TTS feedback is usually 1 word)
                            // 2. Must have reasonable length (8+ chars for 2 words, 12+ for partial results)
                            // 3. Prefer final results, but allow partial if long enough
                            // 4. Must not be noise patterns or TTS feedback
                            let hasMinimumLength = trimmedText.count >= 8 // Lowered from 15 to 8 for responsiveness
                            let hasAtLeastTwoWords = words.count >= 2 // Require 2+ words (TTS feedback is usually 1 word)
                            let hasMultipleWords = words.count >= 2
                            let hasMultipleWordsWithLength = hasMultipleWords && trimmedText.count >= 8 // Lowered from 20 to 8
                            
                            let isFinalResult = result.isFinal
                            
                            // Enhanced TTS feedback detection - filter out very short single words
                            // TTS feedback is usually: 1 word, < 8 chars, or very short partial results
                            let isLikelyTTSFeedback = (words.count < 2) || (trimmedText.count < 8) || (!isFinalResult && trimmedText.count < 12)
                            
                            let isNotNoise = !isLikelyNoise && !isLikelyTTSFeedback
                            
                            // Interrupt if:
                            // - 2+ words with 8+ chars (final result) OR
                            // - 2+ words with 12+ chars (partial result - longer to be safe)
                            // - AND not noise/TTS feedback
                            let shouldInterrupt = (
                                (hasAtLeastTwoWords && hasMinimumLength && isFinalResult) || // 2+ words, 8+ chars, final
                                (hasMultipleWords && trimmedText.count >= 12 && !isFinalResult) // 2+ words, 12+ chars, partial
                            ) && isNotNoise
                            
                            if shouldInterrupt {
                                // User is speaking during playback - but only stop if we have visible text
                                // The recognizedText is set at the start of this block, so it should be visible
                                // But we want to ensure it's meaningful (not just empty or whitespace)
                                // Since we already updated recognizedText = fullText above, it should be visible
                                
                                // Double-check that the text we're about to use for interruption is actually visible
                                // This ensures the UI has had a chance to display it
                                // Require reasonable visible text to prevent false interruptions
                                let currentVisibleText = self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                                let hasVisibleText = !currentVisibleText.isEmpty && currentVisibleText.count >= 8 // Lowered from 15 to 8 for responsiveness
                                
                                if hasVisibleText {
                                    // We have visible text in the input field - safe to stop playback
                                    print("🔊 User interrupted during playback: \(trimmedText.prefix(50))...")
                                    print("🔊 Result is final: \(result.isFinal), Words: \(words.count), Length: \(trimmedText.count)")
                                    print("🔊 Recognized text is visible in input field (\(currentVisibleText.count) chars) - stopping playback")
                                    
                                    // Update last interruption attempt
                                    self.lastInterruptionAttempt = now
                                    
                                    // Stop TTS immediately but KEEP recognition running
                                    // Don't cancel recognition task - let user continue speaking
                                    // Don't end audio on recognition request - keep listening
                                    // Don't mark as not listening - keep the recognition active
                                    // Don't clear isListeningDuringPlayback - we want to keep the state
                                    
                                    // Just trigger interruption callback to stop TTS
                                    // Recognition will continue and update recognizedText
                                    self.onInterruptDetected?(trimmedText)
                                    
                                    // Continue processing - don't return, let recognition keep going
                                    // This allows the user to continue speaking and see the text update
                                    // The recognizedText will keep updating as user speaks
                                } else {
                                    // Text not yet visible or too short - wait for it to appear first
                                    print("⏸️ Interruption detected but text not yet visible (\(currentVisibleText.count) chars) - waiting for recognition to populate input field")
                                }
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
