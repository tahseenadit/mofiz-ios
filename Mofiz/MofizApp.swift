//
//  MofizApp.swift
//  Mofiz
//
//  Created by Farzana Nitol on 2025-11-09.
//

import SwiftUI

@main
struct MofizApp: App {
    let persistenceController = PersistenceController.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.viewContext)
        }
    }
}
