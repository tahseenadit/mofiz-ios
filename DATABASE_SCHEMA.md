# Database Schema Documentation

## Overview
The Mofiz app uses Core Data for local persistence with a normalized, scalable schema designed for future expansion.

## Database Architecture

### Core Data Stack
- **PersistenceController**: Manages the Core Data stack with automatic migration support
- **DatabaseService**: High-level service layer for database operations
- **Model**: `MofizDataModel.xcdatamodeld` - Core Data model definition

## Entity Schema

### 1. User Entity

**Purpose**: Stores user information and preferences

**Attributes**:
- `id` (UUID, Required): Unique identifier for the user
- `name` (String, Optional): User's display name
- `email` (String, Optional): User's email address
- `deviceId` (String, Optional): Device identifier (UIDevice.identifierForVendor)
- `preferences` (Binary, Optional): JSON-encoded user preferences dictionary
- `createdAt` (Date, Required): Timestamp when user was created
- `updatedAt` (Date, Required): Timestamp when user was last updated

**Relationships**:
- `chatHistory` (To-Many, Cascade Delete): All chat conversations belonging to this user

**Design Rationale**:
- UUID primary key for scalability and distributed systems compatibility
- Binary storage for preferences allows flexible JSON schema evolution
- Timestamps enable audit trails and sync capabilities
- Cascade delete ensures data integrity when user is deleted

### 2. ChatThread Entity

**Purpose**: Groups conversations into threads/sessions for better organization

**Attributes**:
- `id` (UUID, Required): Unique identifier for the thread
- `title` (String, Optional): Thread title (auto-generated from first message)
- `isActive` (Boolean, Required): Whether this is the currently active thread
- `lastMessageAt` (Date, Optional): Timestamp of the last message in this thread
- `metadata` (Binary, Optional): JSON-encoded additional metadata
- `createdAt` (Date, Required): Timestamp when thread was created
- `updatedAt` (Date, Required): Timestamp when thread was last updated

**Relationships**:
- `user` (To-One, Nullify): Reference to the User who owns this thread
- `chatHistory` (To-Many, Cascade Delete): All chat conversations in this thread

**Design Rationale**:
- Threads allow grouping related conversations together
- Only one thread can be active per user at a time
- Auto-generated titles from first message improve UX
- Cascade delete ensures thread deletion removes all associated chats

### 3. ChatHistory Entity

**Purpose**: Stores all conversation history between user and AI

**Attributes**:
- `id` (UUID, Required): Unique identifier for the chat entry
- `message` (String, Required): User's input message
- `response` (String, Required): AI's response text
- `language` (String, Optional): Detected language code (e.g., "en", "bn")
- `timestamp` (Date, Required): When the conversation occurred
- `metadata` (Binary, Optional): JSON-encoded additional metadata (model used, token counts, etc.)
- `createdAt` (Date, Required): Timestamp when entry was created
- `updatedAt` (Date, Required): Timestamp when entry was last updated

**Relationships**:
- `user` (To-One, Nullify): Reference to the User who owns this chat
- `thread` (To-One, Nullify): Reference to the ChatThread this chat belongs to

**Design Rationale**:
- UUID primary key for scalability
- Separate message and response fields for clear data separation
- Language field enables future multilingual features
- Metadata as binary JSON allows extensibility without schema changes
- Timestamps support sorting, filtering, and sync operations
- Nullify relationship ensures orphaned chats are preserved if user is deleted (can be changed to cascade if needed)

## Scalability Features

### 1. Normalized Design
- User and ChatHistory are properly normalized with foreign key relationships
- Reduces data duplication and ensures consistency

### 2. Extensible Metadata
- Both entities have optional `metadata`/`preferences` fields stored as JSON
- Allows adding new fields without Core Data schema migrations
- Future fields can be added to metadata without breaking existing code

### 3. UUID Primary Keys
- UUIDs enable distributed systems and sync capabilities
- No auto-incrementing integers that could cause conflicts
- Supports future cloud sync or multi-device scenarios

### 4. Timestamps
- `createdAt` and `updatedAt` on all entities
- Enables efficient querying, sorting, and sync operations
- Supports future features like "recent chats" or "last updated"

### 5. Relationship Design
- Proper cascade/nullify rules for data integrity
- To-many relationships support future features (multiple users, shared chats, etc.)

## Future Extension Points

### Easy to Add:
1. **Session Entity**: Group chats into sessions/conversations
2. **Message Reactions**: Add reactions/feedback to chat history
3. **User Profiles**: Extend User entity with more profile fields
4. **Settings**: Store app settings in User.preferences JSON
5. **Analytics**: Add analytics events table with foreign key to User
6. **Favorites**: Add favorites/bookmarks table
7. **Tags/Categories**: Add tagging system for chat history
8. **Export/Import**: Timestamps enable easy export/import functionality

### Migration Support:
- Core Data is configured with automatic migration (`shouldMigrateStoreAutomatically = true`)
- Future schema changes can be handled via Core Data migration policies
- Metadata JSON fields provide backward compatibility

## Thread Management

### How Threads Work

1. **Active Thread**: Each user has one active thread at a time. New chats are automatically saved to the active thread.
2. **Thread Identification**: Every `ChatHistory` entry has a `thread` relationship, so you can always identify which thread a conversation belongs to.
3. **Automatic Thread Creation**: If no active thread exists, one is automatically created when saving the first chat.
4. **Thread Switching**: You can create a new thread, which automatically deactivates the current one.

### Usage Examples

### Save a Chat (automatically to active thread)
```swift
let databaseService = DatabaseService()
let user = databaseService.getOrCreateCurrentUser()

// Saves to active thread automatically
databaseService.saveChatHistory(
    userId: user.id!,
    message: "Hello, how are you?",
    response: "I'm doing well, thank you!",
    language: "en",
    metadata: ["model": "gpt-4o-mini", "tokens": 150]
)
```

### Save to Specific Thread
```swift
let threadId = UUID() // Your thread ID
databaseService.saveChatHistory(
    userId: user.id!,
    threadId: threadId, // Specify thread
    message: "What's the weather?",
    response: "It's sunny today!",
    language: "en"
)
```

### Get or Create Active Thread
```swift
let activeThread = databaseService.getOrCreateActiveThread(for: user.id!)
print("Active thread ID: \(activeThread.id!)")
print("Thread title: \(activeThread.title ?? "Untitled")")
```

### Create New Thread
```swift
let newThread = databaseService.createNewThread(
    for: user.id!,
    title: "Weather Discussion"
)
// This automatically deactivates the previous active thread
```

### Get All Threads
```swift
let allThreads = databaseService.getAllThreads(for: user.id!)
for thread in allThreads {
    print("Thread: \(thread.title ?? "Untitled") - Active: \(thread.isActive)")
}
```

### Get Chats from Specific Thread
```swift
let threadId = activeThread.id!
let threadChats = databaseService.getChatHistory(forThreadId: threadId)
// Returns all chats in chronological order
```

### Retrieve Recent Chats (from active thread)
```swift
let recentChats = databaseService.getRecentChatHistory(limit: 20)
// Returns chats from the currently active thread
```

### Search Chats in Thread
```swift
// Search all chats
let results = databaseService.searchChatHistory(query: "weather", for: user.id!)

// Search only in specific thread
let threadResults = databaseService.searchChatHistory(
    query: "weather",
    for: user.id!,
    threadId: threadId
)
```

### Get Statistics
```swift
let stats = databaseService.getChatStatistics(for: user.id!)
print("Total chats: \(stats.totalChats)")
```

## Database Location
- **Development**: `~/Library/Developer/CoreSimulator/Devices/[DEVICE_ID]/data/Containers/Data/Application/[APP_ID]/Documents/MofizDataModel.sqlite`
- **Production**: App's Documents directory on device

## Notes
- Core Data automatically handles threading with `viewContext` for UI and `newBackgroundContext()` for heavy operations
- The schema is designed to be cloud-sync ready (UUIDs, timestamps, metadata)
- All database operations are performed through `DatabaseService` for consistency

