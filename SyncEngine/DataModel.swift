//
//  DataModel.swift
//  SyncEngine
//

import CloudKit
import os.log

// MARK: - Data

/// An object representing the entire data model of the app.
struct AppData : Codable {
    
    /// All the contacts in the database.
    var contacts: [Contact.ID : Contact] = [:]
    
    /// The last known state we got from the sync engine.
    var stateSerialization: CKSyncEngine.State.Serialization?
}

/// The main model object for the app.
struct Contact {
    
    /// The unique identifier of this contact. Also used as the CloudKit record name.
    var id: String = UUID().uuidString
    
    /// The name of this contact.
    var name: String = "New Contact \(Self.randomEmoji())"
    
    /// The date this contact was last modified in the UI.
    /// Used for conflict resolution.
    var userModificationDate: Date = Date.distantPast
    
    /// The encoded `CKRecord` system fields last known to be on the server.
    var lastKnownRecordData: Data?
}

extension Contact : Codable, Identifiable, Hashable, Equatable, Sendable, Comparable {
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id &&
               lhs.name == rhs.name &&
               lhs.userModificationDate == rhs.userModificationDate
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.name)
        hasher.combine(self.userModificationDate)
    }
    
    static func < (lhs: Contact, rhs: Contact) -> Bool {
        return lhs.name.localizedCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - CloudKit

extension Contact {
    
    /// The name of the zone used for storing contact records.
    static let zoneName = "Contacts"
    
    /// The record type to use when saving a contact.
    static let recordType: CKRecord.RecordType = "Contact"
    
    /// The zone where this contact record is stored.
    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName) }
    
    /// The CloudKit record ID for this contact.
    var recordID: CKRecord.ID { CKRecord.ID(recordName: self.id, zoneID: self.zoneID) }
    
    /// Merges data from a record into this contact.
    /// This handles any conflict resolution if necessary.
    mutating func mergeFromServerRecord(_ record: CKRecord) {
        
        // Conflict resolution can be a bit tricky.
        // For example, imagine this scenario with two devices:
        //
        // 1. DeviceA has no network connection.
        // 2. DeviceA modifies data.
        // 3. Hours later, DeviceB modifies data.
        // 4. DeviceB sends its changes to the server.
        // 5. DeviceA finally connects to the network and sends its changes.
        //
        // If we go strictly by last-uploader-wins, then we'll end up choosing the data from DeviceA, which is out of date.
        // The user actually wanted the data from DeviceB.
        // In order to find the value the user truly wanted, we keep track of the actual user's modification date.
        // Let's make sure we only merge in the data from the server if the user modification date is newer.
        let userModificationDate: Date
        if let dateFromRecord = record.encryptedValues[.contact_userModificationDate] as? Date {
            userModificationDate = dateFromRecord
        } else {
            Logger.dataModel.info("No user modification date in contact record")
            userModificationDate = Date.distantPast
        }
        
        if userModificationDate > self.userModificationDate {
            self.userModificationDate = userModificationDate
            
            if let name = record.encryptedValues[.contact_name] as? String {
                self.name = name
            } else {
                Logger.dataModel.info("No name in contact record")
            }
        } else {
            Logger.dataModel.info("Not overwriting data from older contact record")
        }
    }
    
    /// Populates a record with the data for this contact.
    func populateRecord(_ record: CKRecord) {
        record.encryptedValues[.contact_name] = self.name
        record.encryptedValues[.contact_userModificationDate] = self.userModificationDate
    }
    
    /// Sets `lastKnownRecordData` for this contact, but only if the other record is a newer version than the existing last known record.
    mutating func setLastKnownRecordIfNewer(_ otherRecord: CKRecord) {
        let localRecord = self.lastKnownRecord
        if let localDate = localRecord?.modificationDate {
            if let otherDate = otherRecord.modificationDate, localDate < otherDate {
                self.lastKnownRecord = otherRecord
            } else {
                // The other record is older than the one we already have.
            }
        } else {
            self.lastKnownRecord = otherRecord
        }
    }
    
    /// A deserialized version of `lastKnownRecordData`.
    /// Will return `nil` if there is no data or if the deserialization fails for some reason.
    var lastKnownRecord: CKRecord? {
        
        get {
            if let data = self.lastKnownRecordData {
                do {
                    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
                    unarchiver.requiresSecureCoding = true
                    return CKRecord(coder: unarchiver)
                } catch {
                    // Why would this happen? What could go wrong? 🔥
                    Logger.dataModel.fault("Failed to decode local system fields record: \(error)")
                    return nil
                }
            } else {
                return nil
            }
        }
        
        set {
            if let newValue {
                let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                newValue.encodeSystemFields(with: archiver)
                self.lastKnownRecordData = archiver.encodedData
            } else {
                self.lastKnownRecordData = nil
            }
        }
    }
}

extension CKRecord.FieldKey {
    
    static let contact_name = "name"
    static let contact_userModificationDate = "userModificationDate"
}

// MARK: - Helpers

extension Contact {
    
    static let contactEmojis = [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎",
        "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "⬛️", "⬜️", "🟫",
        "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️", "🟤",
    ]
    
    static func randomEmoji() -> String {
        return Self.contactEmojis.randomElement() ?? UUID().uuidString
    }
}
