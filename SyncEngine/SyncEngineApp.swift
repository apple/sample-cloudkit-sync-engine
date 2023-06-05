//
//  SyncEngineApp.swift
//  SyncEngine
//

import SwiftUI

@main
struct SyncEngineApp: App {
    
    let database = SyncedDatabase()
    
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContactsList()
                    .environmentObject(self.database)
            }
        }
    }
}
