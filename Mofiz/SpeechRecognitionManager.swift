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
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isIntentionallyStopping = false
    
    var onCommandRecognized: ((String) -> Void)?
    
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
    
    func startListening() {
        guard !isListening else { return }
        
        guard let recognizer = speechRecognizer else {
            statusMessage = "Speech recognizer not available"
            return
        }
        
        guard recognizer.isAvailable else {
            statusMessage = "Speech recognizer not available"
            return
        }
        
        statusMessage = "Listening..."
        
        // Stop any existing recognition
        stopListening()
        
        // Add a small delay to ensure audio session is fully deactivated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupAudioSession()
        }
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // First, deactivate any existing session
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            
            // Configure the audio session for recording
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            
            // Activate the audio session
            try audioSession.setActive(true, options: [])
            
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
            statusMessage = "Listening... Say 'Hello' followed by your command, then tap Send."
            
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
                    
                    DispatchQueue.main.async {
                        self.recognizedText = result.bestTranscription.formattedString
                        
                        // Check for wake word
                        if !self.wakeWordDetected {
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
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Only deactivate if we're the active session
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
        
        isListening = false
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
