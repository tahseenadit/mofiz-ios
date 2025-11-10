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
    
    var body: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 10) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(speechManager.isListening ? .green : .gray)
                    .symbolEffect(.pulse, isActive: speechManager.isListening)
                
                Text("Mofiz")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            .padding(.top, 40)
            
            // Status message
            VStack(spacing: 8) {
                Text(speechManager.statusMessage)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if speechManager.wakeWordDetected {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Wake word detected!")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    .padding(.top, 4)
                }
            }
            
            // Recognized text display
            if !speechManager.recognizedText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recognized:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(speechManager.recognizedText)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(10)
                }
                .padding(.horizontal)
            }
            
            // Sent command display
            if let sentCommand = apiService.lastSentCommand {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.blue)
                        Text("Sent to OpenAI:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(sentCommand)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                }
                .padding(.horizontal)
            }
            
            // API Status and Response
            if apiService.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    if !apiService.statusMessage.isEmpty {
                        Text(apiService.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            } else if let response = apiService.lastResponse {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Response:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(response)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                }
                .padding(.horizontal)
            }
            
            // Error message
            if let error = apiService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // Show buttons based on state
            if !speechManager.recognizedText.isEmpty {
                // Show both Send and Start Again buttons when there's recognized text
                HStack(spacing: 12) {
                    // Start Again button - clears text and starts fresh
                    Button(action: {
                        speechManager.clearAndStartAgain()
                    }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Start Again")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.orange)
                        .cornerRadius(12)
                    }
                    
                    // Send button - sends the recognized text to the API
                    Button(action: {
                        let textToSend = speechManager.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !textToSend.isEmpty {
                            // Stop listening before sending
                            speechManager.stopListening()
                            
                            // Extract command if wake word is present, otherwise send the full text
                            let lowercasedText = textToSend.lowercased()
                            
                            // Check for wake word variations
                            let wakeWordVariations = ["hello", "hallo", "halo"]
                            
                            var commandStartIndex: String.Index?
                            for variation in wakeWordVariations {
                                if let range = lowercasedText.range(of: variation) {
                                    commandStartIndex = range.upperBound
                                    break
                                }
                            }
                            
                            if let startIndex = commandStartIndex {
                                let command = String(textToSend[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !command.isEmpty {
                                    apiService.sendCommand(command)
                                } else {
                                    apiService.sendCommand(textToSend)
                                }
                            } else {
                                // No wake word detected, send the full recognized text
                                apiService.sendCommand(textToSend)
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text("Send")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            
            // Show Stop button and speaking indicator if response is being spoken
            if apiService.isSpeaking {
                VStack(spacing: 12) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Speaking response...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Stop button
                    Button(action: {
                        // Stop speaking first
                        apiService.stopSpeaking()
                        
                        // Wait a moment for audio session to clean up before starting listening
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            // Clear previous response and recognized text
                            speechManager.recognizedText = ""
                            apiService.lastResponse = nil
                            apiService.lastSentCommand = nil
                            apiService.errorMessage = nil
                            
                            // Auto-start listening after stopping speech
                            if !speechManager.isListening {
                                speechManager.startListening()
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "stop.circle.fill")
                            Text("Stop")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 10)
            }
        }
        .onAppear {
            // Auto-start listening when app appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                speechManager.startListening()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SpeechFinished"))) { _ in
            // Clear previous response and recognized text
            speechManager.recognizedText = ""
            apiService.lastResponse = nil
            apiService.lastSentCommand = nil
            apiService.errorMessage = nil
            
            // Auto-start listening after speech finishes
            if !speechManager.isListening {
                speechManager.startListening()
            }
        }
        .onDisappear {
            speechManager.stopListening()
        }
    }
}

#Preview {
    ContentView()
}
