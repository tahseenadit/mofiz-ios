//
//  ChatMessage.swift
//  Mofiz
//
//  Created by Farzana Nitol on 2025-11-13.
//

import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let timestamp: Date
    let isRecognizing: Bool // For showing live recognition
}

