//
//  SyncedDatabase.swift
//  SyncEngine
//

import CloudKit
import Foundation
import os.log

final actor SyncedDatabase : Sendable, ObservableObject {
    
    /// The CloudKit container to sync with.
    static let container: CKContainer = CKContainer(identifier: "iCloud.com.apple.samples.cloudkit.SyncEngine")

    /// The sync engine being used to sync.
    /// This is lazily initialized. You can re-initialize the sync engine by setting `_syncEngine` to nil then calling `self.syncEngine`.
    var syncEngine: CKSyncEngine {
        if _syncEngine == nil {
            self.initializeSyncEngine()
        }
        return _syncEngine!
    }
    var _syncEngine: CKSyncEngine?
    
    /// True if we want the sync engine to sync automatically.
    /// This should always be true in a production app, but we set this to false when testing.
    let automaticallySync: Bool
    
    /// The data to be used by the app's UI.
    @MainActor @Published var viewModel = AppData()
    
    /// The actual data for the app.
    /// If you're accessing this from the UI, you should use `viewModel` instead.
    var appData: AppData {
        didSet {
            // When the data is modified, let's update the view model.
            Task {
                let appData = self.appData
                await MainActor.run {
                    self.viewModel = appData
                }
            }
        }
    }
    
    /// The file URL we use to store our data.
    /// Using a different file in the tests allows us to keep our test data and app data separate.
    let dataURL: URL
    
    /// The default data URL used to store data in the app.
    static let defaultDataURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appending(component: "Contacts").appendingPathExtension("json")
    
    init(automaticallySync: Bool = true, dataURL: URL = defaultDataURL) {
        
        // Load the data from disk.
        // Note that this is not a very efficient way to store data, but this is a sample app.
        self.dataURL = dataURL
        do {
            let appDataBlob = try Data(contentsOf: dataURL)
            self.appData = try JSONDecoder().decode(AppData.self, from: appDataBlob)
        } catch {
            // In a real app, we'd likely have much better error recovery here.
            // However, in a sample application, let's just start from scratch.
            Logger.database.error("Failed to load app data: \(error)")
            self.appData = AppData()
        }
        
        self.automaticallySync = automaticallySync
        
        Task {
            /// We want to initialize our sync engine lazily, but we also want to make sure it happens pretty soon after launch.
            await self.initializeSyncEngine()
        }
    }
    
    func initializeSyncEngine() {
        var configuration = CKSyncEngine.Configuration(
            database: Self.container.privateCloudDatabase,
            stateSerialization: self.appData.stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = self.automaticallySync
        let syncEngine = CKSyncEngine(configuration)
        _syncEngine = syncEngine
        Logger.database.log("Initialized sync engine: \(syncEngine)")
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncedDatabase : CKSyncEngineDelegate {
    
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        
        Logger.database.debug("Handling event \(event)")
        
        switch event {
            
        case .stateUpdate(let event):
            self.appData.stateSerialization = event.stateSerialization
            try? self.persistLocalData() // This error should be handled, but we'll skip that for brevity in this sample app.
            
        case .accountChange(let event):
            self.handleAccountChange(event)
            
        case .fetchedDatabaseChanges(let event):
            self.handleFetchedDatabaseChanges(event)
            
        case .fetchedRecordZoneChanges(let event):
            self.handleFetchedRecordZoneChanges(event)
            
        case .sentRecordZoneChanges(let event):
            self.handleSentRecordZoneChanges(event)
            
        case .sentDatabaseChanges:
            // The sample app doesn't track sent database changes in any meaningful way, but this might be useful depending on your data model.
            break
            
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            // We don't do anything here in the sample app, but these events might be helpful if you need to do any setup/cleanup when sync starts/ends.
            break
            
        @unknown default:
            Logger.database.info("Received unknown event: \(event)")
        }
    }
    
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        
        Logger.database.info("Returning next record change batch for context: \(context)")
        
        let zoneIDs = context.options.zoneIDs
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { zoneIDs.contains($0.recordID.zoneID) }
        let contacts = self.appData.contacts
        
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            
            if let contact = contacts[recordID.recordName] {
                let record = contact.lastKnownRecord ?? CKRecord(recordType: Contact.recordType, recordID: recordID)
                contact.populateRecord(record)
                return record
            } else {
                // We might have pending changes that no longer exist in our database. We can remove those from the state.
                syncEngine.state.remove(pendingRecordZoneChanges: [.save(recordID)])
                return nil
            }
        }
        return batch
    }
    
    // MARK: - CKSyncEngine Events
    
    func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        
        for modification in event.modifications {
            
            // The sync engine fetched a record, and we want to merge it into our local persistence.
            // If we already have this object locally, let's merge the data from the server.
            // Otherwise, let's create a new local object.
            let record = modification.record
            let id = record.recordID.recordName
            Logger.database.log("Received contact modification: \(record.recordID)")
            
            var contact: Contact = self.appData.contacts[id] ?? Contact(id: id)
            contact.mergeFromServerRecord(record)
            contact.setLastKnownRecordIfNewer(record)
            self.appData.contacts[id] = contact
        }
        
        for deletion in event.deletions {
            
            // A record was deleted on the server, so let's remove it from our local persistence.
            Logger.database.log("Received contact deletion: \(deletion.recordID)")
            let id = deletion.recordID.recordName
            self.appData.contacts[id] = nil
        }
        
        // If we had any changes, let's save to disk.
        if !event.modifications.isEmpty || !event.deletions.isEmpty {
            try? self.persistLocalData() // This error should be handled, but we'll skip that for brevity in this sample app.
        }
    }
    
    func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        
        // If a zone was deleted, we should delete everything for that zone locally.
        var needsToSave = false
        for deletion in event.deletions {
            switch deletion.zoneID.zoneName {
            case Contact.zoneName:
                self.appData.contacts = [:]
                needsToSave = true
            default:
                Logger.database.info("Received deletion for unknown zone: \(deletion.zoneID)")
            }
        }
        
        if needsToSave {
            try? self.persistLocalData() // This error should be handled, but we'll skip that for brevity in this sample app.
        }
    }
    
    func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        
        // If we failed to save a record, we might want to retry depending on the error code.
        var newPendingRecordZoneChanges = [CKSyncEngine.PendingRecordZoneChange]()
        var newPendingDatabaseChanges = [CKSyncEngine.PendingDatabaseChange]()
        
        // Update the last known server record for each of the saved records.
        for savedRecord in event.savedRecords {
            
            let id = savedRecord.recordID.recordName
            if var contact = self.appData.contacts[id] {
                contact.setLastKnownRecordIfNewer(savedRecord)
                self.appData.contacts[id] = contact
            }
        }
        
        // Handle any failed record saves.
        for failedRecordSave in event.failedRecordSaves {
            let failedRecord = failedRecordSave.record
            let contactID = failedRecord.recordID.recordName
            var shouldClearServerRecord = false
            
            switch failedRecordSave.error.code {
                
            case .serverRecordChanged:
                // Let's merge the record from the server into our own local copy.
                // The `mergeFromServerRecord` function takes care of the conflict resolution.
                guard let serverRecord = failedRecordSave.error.serverRecord else {
                    Logger.database.error("No server record for conflict \(failedRecordSave.error)")
                    continue
                }
                guard var contact = self.appData.contacts[contactID] else {
                    Logger.database.error("No local object for conflict \(failedRecordSave.error)")
                    continue
                }
                contact.mergeFromServerRecord(serverRecord)
                contact.setLastKnownRecordIfNewer(serverRecord)
                self.appData.contacts[contactID] = contact
                newPendingRecordZoneChanges.append(.save(failedRecord.recordID))
                
            case .zoneNotFound:
                // Looks like we tried to save a record in a zone that doesn't exist.
                // Let's save that zone and retry saving the record.
                // Also clear the last known server record if we have one, it's no longer valid.
                let zone = CKRecordZone(zoneID: failedRecord.recordID.zoneID)
                newPendingDatabaseChanges.append(.save(zone))
                newPendingRecordZoneChanges.append(.save(failedRecord.recordID))
                shouldClearServerRecord = true
                
            case .unknownItem:
                // We tried to save a record with a locally-cached server record, but that record no longer exists on the server.
                // This might mean that another device deleted the record, but we still have the data for that record locally.
                // We have the choice of either deleting the local data or re-uploading the local data.
                // For this sample app, let's re-upload the local data.
                newPendingRecordZoneChanges.append(.save(failedRecord.recordID))
                shouldClearServerRecord = true
                
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled:
                // There are several errors that the sync engine will automatically retry, let's just log and move on.
                Logger.database.debug("Retryable error saving \(failedRecord.recordID): \(failedRecordSave.error)")
                
            default:
                // We got an error, but we don't know what it is or how to handle it.
                // If you have any sort of telemetry system, you should consider tracking this scenario so you can understand which errors you see in the wild.
                Logger.database.fault("Unknown error saving record \(failedRecord.recordID): \(failedRecordSave.error)")
            }
            
            if shouldClearServerRecord {
                if var contact = self.appData.contacts[contactID] {
                    contact.lastKnownRecord = nil
                    self.appData.contacts[contactID] = contact
                }
            }
        }
        
        self.syncEngine.state.add(pendingDatabaseChanges: newPendingDatabaseChanges)
        self.syncEngine.state.add(pendingRecordZoneChanges: newPendingRecordZoneChanges)
        
        // Now that we've processed the batch, save to disk.
        try? self.persistLocalData()
    }
    
    func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        
        // Handling account changes can be tricky.
        //
        // If the user signed out of their account, we want to delete all local data.
        // However, what if there's some data that hasn't been uploaded yet?
        // Should we keep that data? Prompt the user to keep the data? Or just delete it?
        //
        // Also, what if the user signs in to a new account, and there's already some data locally?
        // Should we upload it to their account? Or should we delete it?
        //
        // Finally, what if the user signed in, but they were signed into a previous account before?
        //
        // Since we're in a sample app, we're going to take a relatively simple approach.
        let shouldDeleteLocalData: Bool
        let shouldReUploadLocalData: Bool
        
        switch event.changeType {
            
        case .signIn:
            shouldDeleteLocalData = false
            shouldReUploadLocalData = true
            
        case .switchAccounts:
            shouldDeleteLocalData = true
            shouldReUploadLocalData = false
            
        case .signOut:
            shouldDeleteLocalData = true
            shouldReUploadLocalData = false
            
        @unknown default:
            Logger.database.log("Unknown account change type: \(event)")
            shouldDeleteLocalData = false
            shouldReUploadLocalData = false
        }
        
        if shouldDeleteLocalData {
            try? self.deleteLocalData() // This error should be handled, but we'll skip that for brevity in this sample app.
        }
        
        if shouldReUploadLocalData {
            let recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = self.appData.contacts.values.map { .save($0.recordID) }
            let zoneIDsToSave = Set(recordZoneChanges.map { $0.recordID.zoneID })
            let databaseChanges: [CKSyncEngine.PendingDatabaseChange] = zoneIDsToSave.map { .save(CKRecordZone(zoneID: $0)) }
            
            self.syncEngine.state.add(pendingDatabaseChanges: databaseChanges)
            self.syncEngine.state.add(pendingRecordZoneChanges: recordZoneChanges)
        }
    }
}

// MARK: - Data

extension SyncedDatabase {
    
    func saveContacts(_ contacts: [Contact]) throws {
        for var contact in contacts {
            // Make sure we don't accidentally overwrite the existing last known record.
            if let existingRecord = self.appData.contacts[contact.id]?.lastKnownRecord {
                contact.setLastKnownRecordIfNewer(existingRecord)
            }
            
            self.appData.contacts[contact.id] = contact
        }
        try self.persistLocalData()
        
        let pendingSaves: [CKSyncEngine.PendingRecordZoneChange] = contacts.map { .save($0.recordID) }
        self.syncEngine.state.add(pendingRecordZoneChanges: pendingSaves)
    }
    
    func deleteContacts(_ ids: [Contact.ID]) throws {
        let contacts = ids.compactMap { self.appData.contacts[$0] }
        for id in ids {
            self.appData.contacts[id] = nil
        }
        try self.persistLocalData()
        
        let pendingDeletions: [CKSyncEngine.PendingRecordZoneChange] = contacts.map { .delete($0.recordID) }
        self.syncEngine.state.add(pendingRecordZoneChanges: pendingDeletions)
    }
    
    func deleteLocalData() throws {
        Logger.database.info("Deleting local data")
        
        self.appData = AppData()
        try self.persistLocalData()
        
        // If we're deleting everything, we need to clear out all our sync engine state too.
        // In order to do that, let's re-initialize our sync engine.
        self.initializeSyncEngine()
    }
    
    func persistLocalData() throws {
        Logger.database.debug("Saving to disk")
        do {
            let data = try JSONEncoder().encode(self.appData)
            try data.write(to: self.dataURL)
        } catch {
            Logger.database.error("Failed to save to disk: \(error)")
            throw error
        }
    }
    
    func deleteServerData() async throws {
        Logger.database.info("Deleting server data")
        
        // Our data is all in a single zone. Let's delete that zone now.
        let zoneID = CKRecordZone.ID(zoneName: Contact.zoneName)
        self.syncEngine.state.add(pendingDatabaseChanges: [ .delete(zoneID) ])
        try await self.syncEngine.sendChanges()
    }
}
