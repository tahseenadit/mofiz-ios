//
//  DatabaseService.swift
//  Mofiz
//
//  Created by Farzana Nitol on 2025-11-09.
//

import CoreData
import Foundation
import UIKit

class DatabaseService: ObservableObject {
    private let persistenceController: PersistenceController
    private var viewContext: NSManagedObjectContext {
        return persistenceController.viewContext
    }
    
    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }
    
    // MARK: - User Operations
    
    /// Get or create the current user (singleton pattern for single-user app)
    func getOrCreateCurrentUser() -> User {
        let request: NSFetchRequest<User> = User.fetchRequest()
        request.fetchLimit = 1
        
        if let existingUser = try? viewContext.fetch(request).first {
            return existingUser
        }
        
        // Create new user
        let newUser = User(context: viewContext)
        newUser.id = UUID()
        newUser.createdAt = Date()
        newUser.updatedAt = Date()
        
        // Set device identifier if available
        if let deviceId = UIDevice.current.identifierForVendor?.uuidString {
            newUser.deviceId = deviceId
        }
        
        // Set default name
        newUser.name = "User"
        
        persistenceController.save()
        return newUser
    }
    
    /// Update user information
    func updateUser(id: UUID, name: String? = nil, email: String? = nil, preferences: [String: Any]? = nil) {
        let request: NSFetchRequest<User> = User.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        guard let user = try? viewContext.fetch(request).first else {
            print("❌ User not found with id: \(id)")
            return
        }
        
        if let name = name {
            user.name = name
        }
        if let email = email {
            user.email = email
        }
        if let preferences = preferences {
            user.preferences = try? JSONSerialization.data(withJSONObject: preferences)
        }
        
        user.updatedAt = Date()
        persistenceController.save()
    }
    
    /// Get user by ID
    func getUser(by id: UUID) -> User? {
        let request: NSFetchRequest<User> = User.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try? viewContext.fetch(request).first
    }
    
    // MARK: - Chat Thread Operations
    
    /// Get or create the active thread for a user
    func getOrCreateActiveThread(for userId: UUID) -> ChatThread {
        let user = getUser(by: userId) ?? getOrCreateCurrentUser()
        
        // First, try to find an active thread
        let request: NSFetchRequest<ChatThread> = ChatThread.fetchRequest()
        request.predicate = NSPredicate(format: "user.id == %@ AND isActive == YES", userId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChatThread.lastMessageAt, ascending: false)]
        request.fetchLimit = 1
        
        if let activeThread = try? viewContext.fetch(request).first {
            return activeThread
        }
        
        // No active thread found, create a new one
        let newThread = ChatThread(context: viewContext)
        newThread.id = UUID()
        newThread.user = user
        newThread.isActive = true
        newThread.createdAt = Date()
        newThread.updatedAt = Date()
        newThread.lastMessageAt = Date()
        newThread.title = "New Conversation"
        
        persistenceController.save()
        print("✅ Created new active thread: \(newThread.id?.uuidString ?? "unknown")")
        return newThread
    }
    
    /// Create a new thread (and deactivate the current one)
    func createNewThread(for userId: UUID, title: String? = nil) -> ChatThread {
        let user = getUser(by: userId) ?? getOrCreateCurrentUser()
        
        // Deactivate all existing threads for this user
        let request: NSFetchRequest<ChatThread> = ChatThread.fetchRequest()
        request.predicate = NSPredicate(format: "user.id == %@ AND isActive == YES", userId as CVarArg)
        
        if let activeThreads = try? viewContext.fetch(request) {
            activeThreads.forEach { $0.isActive = false }
        }
        
        // Create new active thread
        let newThread = ChatThread(context: viewContext)
        newThread.id = UUID()
        newThread.user = user
        newThread.isActive = true
        newThread.createdAt = Date()
        newThread.updatedAt = Date()
        newThread.lastMessageAt = Date()
        newThread.title = title ?? "New Conversation"
        
        persistenceController.save()
        print("✅ Created new thread: \(newThread.id?.uuidString ?? "unknown")")
        return newThread
    }
    
    /// Get thread by ID
    func getThread(by id: UUID) -> ChatThread? {
        let request: NSFetchRequest<ChatThread> = ChatThread.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try? viewContext.fetch(request).first
    }
    
    /// Get all threads for a user
    func getAllThreads(for userId: UUID, limit: Int? = nil) -> [ChatThread] {
        let request: NSFetchRequest<ChatThread> = ChatThread.fetchRequest()
        request.predicate = NSPredicate(format: "user.id == %@", userId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChatThread.lastMessageAt, ascending: false)]
        
        if let limit = limit {
            request.fetchLimit = limit
        }
        
        return (try? viewContext.fetch(request)) ?? []
    }
    
    /// Delete a thread (and all its chat history)
    func deleteThread(id: UUID) {
        let request: NSFetchRequest<ChatThread> = ChatThread.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        if let thread = try? viewContext.fetch(request).first {
            viewContext.delete(thread)
            persistenceController.save()
        }
    }
    
    /// Update thread title
    func updateThreadTitle(id: UUID, title: String) {
        guard let thread = getThread(by: id) else { return }
        thread.title = title
        thread.updatedAt = Date()
        persistenceController.save()
    }
    
    // MARK: - Chat History Operations
    
    /// Save a chat conversation to a specific thread
    func saveChatHistory(
        userId: UUID,
        threadId: UUID? = nil,
        message: String,
        response: String,
        language: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        let user = getUser(by: userId) ?? getOrCreateCurrentUser()
        
        // Get or create thread
        let thread: ChatThread
        if let threadId = threadId, let existingThread = getThread(by: threadId) {
            thread = existingThread
        } else {
            // Use active thread or create new one
            thread = getOrCreateActiveThread(for: userId)
        }
        
        // Check if this is the first message in the thread (before saving)
        let isFirstMessage: Bool
        if let threadId = thread.id {
            let existingChats = getChatHistory(forThreadId: threadId, limit: 1)
            isFirstMessage = existingChats.isEmpty
        } else {
            isFirstMessage = false
        }
        
        let chatHistory = ChatHistory(context: viewContext)
        chatHistory.id = UUID()
        chatHistory.user = user
        chatHistory.thread = thread
        chatHistory.message = message
        chatHistory.response = response
        chatHistory.timestamp = Date()
        chatHistory.language = language
        chatHistory.createdAt = Date()
        chatHistory.updatedAt = Date()
        
        if let metadata = metadata {
            chatHistory.metadata = try? JSONSerialization.data(withJSONObject: metadata)
        }
        
        // Update thread's last message timestamp
        thread.lastMessageAt = Date()
        thread.updatedAt = Date()
        
        // Auto-generate thread title from first message if title is default
        if isFirstMessage && (thread.title == "New Conversation" || thread.title == nil) {
            // This is the first message - use it as title
            let title = String(message.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
            thread.title = title.isEmpty ? "New Conversation" : title
            print("📝 Set thread title to: \(thread.title ?? "Unknown")")
        }
        
        persistenceController.save()
        print("✅ Saved chat history to thread \(thread.id?.uuidString ?? "unknown"): \(message.prefix(50))...")
    }
    
    /// Get all chat history for a user
    func getChatHistory(for userId: UUID, limit: Int? = nil) -> [ChatHistory] {
        let request: NSFetchRequest<ChatHistory> = ChatHistory.fetchRequest()
        request.predicate = NSPredicate(format: "user.id == %@", userId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChatHistory.timestamp, ascending: false)]
        
        if let limit = limit {
            request.fetchLimit = limit
        }
        
        return (try? viewContext.fetch(request)) ?? []
    }
    
    /// Get chat history for a specific thread
    func getChatHistory(forThreadId threadId: UUID, limit: Int? = nil) -> [ChatHistory] {
        let request: NSFetchRequest<ChatHistory> = ChatHistory.fetchRequest()
        request.predicate = NSPredicate(format: "thread.id == %@", threadId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChatHistory.timestamp, ascending: true)]
        
        if let limit = limit {
            request.fetchLimit = limit
        }
        
        return (try? viewContext.fetch(request)) ?? []
    }
    
    /// Get recent chat history (last N conversations) - from active thread
    func getRecentChatHistory(limit: Int = 50) -> [ChatHistory] {
        let user = getOrCreateCurrentUser()
        guard let userId = user.id else { return [] }
        
        let activeThread = getOrCreateActiveThread(for: userId)
        guard let threadId = activeThread.id else { return [] }
        
        return getChatHistory(forThreadId: threadId, limit: limit)
    }
    
    /// Delete a chat history entry
    func deleteChatHistory(id: UUID) {
        let request: NSFetchRequest<ChatHistory> = ChatHistory.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        if let chatHistory = try? viewContext.fetch(request).first {
            viewContext.delete(chatHistory)
            persistenceController.save()
        }
    }
    
    /// Delete all chat history for a user
    func deleteAllChatHistory(for userId: UUID) {
        let request: NSFetchRequest<ChatHistory> = ChatHistory.fetchRequest()
        request.predicate = NSPredicate(format: "user.id == %@", userId as CVarArg)
        
        if let chatHistories = try? viewContext.fetch(request) {
            chatHistories.forEach { viewContext.delete($0) }
            persistenceController.save()
        }
    }
    
    /// Search chat history by message or response content
    func searchChatHistory(query: String, for userId: UUID, threadId: UUID? = nil) -> [ChatHistory] {
        let request: NSFetchRequest<ChatHistory> = ChatHistory.fetchRequest()
        var predicates: [NSPredicate] = [
            NSPredicate(format: "user.id == %@", userId as CVarArg),
            NSPredicate(format: "message CONTAINS[cd] %@ OR response CONTAINS[cd] %@", query, query)
        ]
        
        if let threadId = threadId {
            predicates.append(NSPredicate(format: "thread.id == %@", threadId as CVarArg))
        }
        
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChatHistory.timestamp, ascending: false)]
        
        return (try? viewContext.fetch(request)) ?? []
    }
    
    /// Get chat statistics for a user
    func getChatStatistics(for userId: UUID) -> (totalChats: Int, firstChat: Date?, lastChat: Date?) {
        let request: NSFetchRequest<ChatHistory> = ChatHistory.fetchRequest()
        request.predicate = NSPredicate(format: "user.id == %@", userId as CVarArg)
        
        guard let chats = try? viewContext.fetch(request) else {
            return (0, nil, nil)
        }
        
        let sortedChats = chats.sorted { ($0.timestamp ?? Date.distantPast) < ($1.timestamp ?? Date.distantPast) }
        let firstChat = sortedChats.first?.timestamp
        let lastChat = sortedChats.last?.timestamp
        
        return (chats.count, firstChat, lastChat)
    }
}

