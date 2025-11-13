//
//  ContentView.swift
//  Mofiz
//
//  Created by Farzana Nitol on 2025-11-09.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var speechManager = SpeechRecognitionManager()
    @StateObject private var apiService = APIService()
    @StateObject private var databaseService = DatabaseService()
    @State private var messages: [ChatMessage] = []
    @State private var currentRecognizingText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mofiz")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(speechManager.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(speechManager.isListening ? .green : .gray)
                    .symbolEffect(.pulse, isActive: speechManager.isListening)
            }
            .padding()
            .background(Color(.systemBackground))
            
            Divider()
            
            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                        }
                        
                        // Show current recognizing text
                        if !currentRecognizingText.isEmpty {
                            ChatBubbleView(message: ChatMessage(
                                text: currentRecognizingText,
                                isUser: true,
                                timestamp: Date(),
                                isRecognizing: true
                            ))
                        }
                        
                        // Show loading indicator
                        if apiService.isLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: currentRecognizingText) { _ in
                    if !currentRecognizingText.isEmpty {
                        withAnimation {
                            if let lastMessage = messages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // Bottom controls
            VStack(spacing: 8) {
                // Show recognized text input area when:
                // 1. Listening during playback (even if no text yet)
                // 2. We have recognized text (even if not listening)
                // This ensures it stays visible after interruption
                if speechManager.isListeningDuringPlayback || !currentRecognizingText.isEmpty {
                    HStack {
                        if currentRecognizingText.isEmpty && speechManager.isListeningDuringPlayback {
                            // Show placeholder when listening but no text yet
                            Text("Listening...")
                                .font(.body)
                                .foregroundColor(.secondary.opacity(0.6))
                                .italic()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(20)
                        } else if !currentRecognizingText.isEmpty {
                            // Show recognized text (keep visible even after interruption)
                            Text(currentRecognizingText)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(20)
                        }
                        Spacer()
                        // Show send button when we have text (even if not actively listening)
                        if !currentRecognizingText.isEmpty {
                            Button(action: {
                                sendCurrentText()
                            }) {
                                Image(systemName: "paperplane.fill")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .padding(.horizontal)
                    .transition(.opacity) // Smooth transition when appearing
                }
                
                // Control buttons
                HStack(spacing: 12) {
                    // New Thread button
                    Button(action: {
                        createNewThread()
                    }) {
                        Image(systemName: "plus.message")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .cornerRadius(12)
                    }
                    
                    // Stop button (when speaking)
                    if apiService.isSpeaking {
                        Button(action: {
                            apiService.stopSpeaking()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if !speechManager.isListening {
                                    speechManager.startListening()
                                }
                            }
                        }) {
                            Image(systemName: "stop.circle.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.red)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
        .onAppear {
            // Auto-start listening when app appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                speechManager.startListening()
            }
            
            // Setup interruption handler
            speechManager.onInterruptDetected = { [weak speechManager, weak apiService] interruptedText in
                guard let speechManager = speechManager, let apiService = apiService else { return }
                
                print("🛑 Interruption detected, stopping TTS only (keeping recognition active): \(interruptedText.prefix(50))...")
                
                // Stop speaking immediately (but don't send automatically)
                // Keep recognition running so user can continue speaking
                apiService.stopSpeaking()
                
                // IMPORTANT: Don't stop listening - recognition should continue
                // Don't clear recognizedText - keep it visible in input field
                // Don't change isListeningDuringPlayback - keep the state
                // The recognized text will keep updating in the input field
                // User can manually send using the send button when ready
                
                // Ensure recognition is still active
                if !speechManager.isListening {
                    print("⚠️ Recognition stopped unexpectedly - restarting...")
                    // Restart recognition if it stopped
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        speechManager.startListening(duringPlayback: true)
                    }
                }
                
                print("✅ TTS stopped. Recognition continues. User can send manually using the send button.")
            }
        }
        .onChange(of: speechManager.recognizedText) { newText in
            // Update current recognizing text in real-time
            currentRecognizingText = newText
        }
        .onChange(of: apiService.lastSentCommand) { command in
            if let command = command, !command.isEmpty {
                // Add user message to chat (only if not already added)
                // Check if the last message is the same to avoid duplicates
                if messages.last?.text != command {
                    addMessage(text: command, isUser: true)
                }
                currentRecognizingText = ""
            }
        }
        .onChange(of: apiService.lastResponse) { response in
            if let response = response, !response.isEmpty {
                // Add assistant response to chat
                addMessage(text: response, isUser: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SpeechStarted"))) { notification in
            // Start listening for interruptions immediately when speech starts
            // No delay - start recognition right away to catch all words
            if !speechManager.isListening {
                // Start immediately, no delay
                speechManager.startListening(duringPlayback: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SpeechFinished"))) { _ in
            // Only handle SpeechFinished if TTS finished naturally (not interrupted)
            // If user interrupted, we don't want to clear the input field or stop recognition
            // Check if we're still in playback mode - if so, user might have interrupted
            if speechManager.isListeningDuringPlayback {
                // Still in playback mode - this means TTS finished naturally (not interrupted)
                // Stop listening and clear for next cycle
                speechManager.stopListening()
                
                // Clear previous response and recognized text
                speechManager.recognizedText = ""
                currentRecognizingText = ""
                apiService.lastResponse = nil
                apiService.lastSentCommand = nil
                apiService.errorMessage = nil
                
                // Auto-start listening after speech finishes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !speechManager.isListening {
                        speechManager.startListening()
                    }
                }
            } else {
                // Not in playback mode - normal listening mode
                speechManager.recognizedText = ""
                currentRecognizingText = ""
                apiService.lastResponse = nil
                apiService.lastSentCommand = nil
                apiService.errorMessage = nil
                
                // Auto-start listening after speech finishes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !speechManager.isListening {
                        speechManager.startListening()
                    }
                }
            }
        }
        .onDisappear {
            speechManager.stopListening()
        }
    }
    
    // MARK: - Helper Functions
    
    private func addMessage(text: String, isUser: Bool) {
        let message = ChatMessage(
            text: text,
            isUser: isUser,
            timestamp: Date(),
            isRecognizing: false
        )
        messages.append(message)
    }
    
    private func sendCurrentText() {
        let textToSend = currentRecognizingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !textToSend.isEmpty {
            // Stop TTS if playing
            if apiService.isSpeaking {
                apiService.stopSpeaking()
            }
            
            // Stop listening before sending
            speechManager.stopListening()
            
            // Extract command if wake word is present
            let lowercasedText = textToSend.lowercased()
            let wakeWordVariations = ["hello", "hallo", "halo"]
            
            var commandStartIndex: String.Index?
            for variation in wakeWordVariations {
                if let range = lowercasedText.range(of: variation) {
                    commandStartIndex = range.upperBound
                    break
                }
            }
            
            let command: String
            if let startIndex = commandStartIndex {
                command = String(textToSend[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                command = textToSend
            }
            
            if !command.isEmpty {
                // Check if this is during playback (interruption) or normal send
                let isInterruption = apiService.isSpeaking || speechManager.isListeningDuringPlayback
                apiService.sendCommand(command, isInterruption: isInterruption)
            }
            
            currentRecognizingText = ""
        }
    }
    
    private func createNewThread() {
        apiService.createNewThread()
        messages.removeAll()
        currentRecognizingText = ""
        speechManager.clearAndStartAgain()
    }
}

// MARK: - Chat Bubble View

struct ChatBubbleView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 50)
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isUser ? .white : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        message.isUser
                            ? Color.blue
                            : (message.isRecognizing ? Color.gray.opacity(0.2) : Color.gray.opacity(0.1))
                    )
                    .cornerRadius(18)
                
                if message.isRecognizing {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 4, height: 4)
                            .opacity(0.6)
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 4, height: 4)
                            .opacity(0.6)
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 4, height: 4)
                            .opacity(0.6)
                    }
                    .padding(.top, 4)
                }
            }
            
            if !message.isUser {
                Spacer(minLength: 50)
            }
        }
    }
}

#Preview {
    ContentView()
}
