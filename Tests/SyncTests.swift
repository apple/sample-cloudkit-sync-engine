//
//  SyncTests.swift
//  Tests
//

import CloudKit
import XCTest

/// These tests are an example of how you might write tests for your integration with `CKSyncEngine`.
/// Many of them simulate multiple devices syncing with each other by creating two sync engines side by side.
final class SyncTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Clear out the server data before every test.
        // This makes sure each test starts out with a clean database.
        //
        // Note that this is potentially dangerous if you're running tests for an app with real precious data in it.
        // When building your own tests, you might want something slightly smarter.
        // For example, your tests might save data to a special test zone, or even a completely separate test container.
        let zoneID = CKRecordZone.ID(zoneName: Contact.zoneName)
        try await SyncedDatabase.container.privateCloudDatabase.deleteRecordZone(withID: zoneID)
    }
    
    // MARK: - Simple Sync

    func testSyncContact_single() async throws {
        try await self.testSyncContacts(count: 1)
    }
    
    func testSyncContact_multiple() async throws {
        try await self.testSyncContacts(count: 10)
    }
    
    func testSyncContact_hundreds() async throws {
        try await self.testSyncContacts(count: 444)
    }
    
    /// A test that performs a simple sync of an arbitrary number of contacts from one device to another.
    func testSyncContacts(count: Int) async throws {
        let databaseA = self.newTestDatabase()
        let databaseB = self.newTestDatabase()
        
        // Save the contacts locally.
        let contacts = (0..<count).map { Contact(name: "\($0)", userModificationDate: Date()) }
        try await databaseA.saveContacts(contacts)

        // Send changes to the server.
        try await databaseA.syncEngine.sendChanges()
        
        // Before we fetch on the other device, let's make sure it doesn't accidentally already have this data.
        let contactsBeforeFetch = await databaseB.appData.contacts.values
        XCTAssert(contactsBeforeFetch.isEmpty)
        
        // Now try to fetch it on another device.
        try await databaseB.syncEngine.fetchChanges()
        let contactsAfterFetch = await databaseB.appData.contacts.values
        XCTAssertEqual(Set(contacts), Set(contactsAfterFetch))
    }
    
    /// A test to make sure we can sync a name change of a contact across two devices.
    func testSyncContact_rename() async throws {
        let databaseA = self.newTestDatabase()
        let databaseB = self.newTestDatabase()
        
        // Save the contact with DeviceA and send it to the server.
        var contactA = Contact(name: "Name 1", userModificationDate: Date())
        try await databaseA.saveContacts([contactA])
        try await databaseA.syncEngine.sendChanges()
        
        // Fetch changes on DeviceB to get the contact, change the name, and send it to the server.
        try await databaseB.syncEngine.fetchChanges()
        var allContactsB = await databaseB.appData.contacts
        XCTAssertEqual(allContactsB.count, 1)
        var contactB = try XCTUnwrap(allContactsB[contactA.id])
        XCTAssertEqual(contactB.name, "Name 1")
        contactB.name = "Name 2"
        contactB.userModificationDate = Date()
        try await databaseB.saveContacts([contactB])
        try await databaseB.syncEngine.sendChanges()
        
        // Fetch on DeviceA to get the rename.
        try await databaseA.syncEngine.fetchChanges()
        let allContactsA = await databaseA.appData.contacts
        XCTAssertEqual(allContactsA.count, 1)
        contactA = try XCTUnwrap(allContactsA[contactA.id])
        XCTAssertEqual(contactA.name, "Name 2")
        
        // Now let's try to save a change in the opposite direction.
        // Rename on DeviceA and send that to the server.
        contactA.name = "Name 3"
        contactA.userModificationDate = Date()
        try await databaseA.saveContacts([contactA])
        try await databaseA.syncEngine.sendChanges()
        
        // Finally, fetch on DeviceB and make sure we got the new rename.
        try await databaseB.syncEngine.fetchChanges()
        allContactsB = await databaseB.appData.contacts
        XCTAssertEqual(allContactsB.count, 1)
        contactB = try XCTUnwrap(allContactsB[contactA.id])
        XCTAssertEqual(contactB.name, "Name 3")
    }
    
    // MARK: - Save Failures
    
    /// Test to make sure we properly handle a `.zoneNotFound` error by re-uploading the zone.
    func testSaveFailure_zoneNotFound() async throws {
        let database = self.newTestDatabase()
        
        // First, save a contact to the server so that we have some data there.
        var contact = Contact(name: "I am a contact!", userModificationDate: Date())
        try await database.saveContacts([contact])
        try await database.syncEngine.sendChanges()
        
        // Remember the initial creation date of the contact record for later.
        guard let originalRecordCreationDate = await database.appData.contacts[contact.id]?.lastKnownRecord?.creationDate else {
            XCTFail("Failed to get original creation date for contact record")
            return
        }
        
        // Delete the zone on the side to make it look like another device deleted it.
        try await database.syncEngine.database.deleteRecordZone(withID: CKRecordZone.ID(zoneName: Contact.zoneName))
        
        // Now make a change to the contact and try to upload it.
        contact.name = "I am a renamed contact!"
        contact.userModificationDate = Date()
        try await database.saveContacts([contact])
        
        // The first time we try to save, we'll get a .zoneNotFound error.
        // We should make sure we properly discarded the last known record system fields.
        do {
            try await database.syncEngine.sendChanges()
            XCTFail("Did not expect to succeed in sending changes")
        } catch {
            // Success! We expected to fail!
        }
        let lastKnownRecordAfterZoneNotFound = await database.appData.contacts[contact.id]?.lastKnownRecord
        XCTAssertNil(lastKnownRecordAfterZoneNotFound)
        
        // Now let's try to save again, and it should succeed.
        try await database.syncEngine.sendChanges()
        
        // Now try fetching the contact on another device and make sure we got the new name.
        let databaseB = self.newTestDatabase()
        try await databaseB.syncEngine.fetchChanges()
        guard let contactB = await databaseB.appData.contacts[contact.id] else {
            XCTFail("Failed to get contact on second device")
            return
        }
        let recordCreationDateAfterSave = try XCTUnwrap(contactB.lastKnownRecord?.creationDate)
        XCTAssertNotEqual(recordCreationDateAfterSave, originalRecordCreationDate)
        XCTAssertEqual(contact, contactB)
    }
    
    /// Test to make sure we properly handle an `.unknownItem` error by re-uploading the record.
    func testSaveFailure_unknownItem() async throws {
        let database = self.newTestDatabase()
        
        // First, save a contact to the server so that we have some data there.
        var contact = Contact(name: "I am a contact!", userModificationDate: Date())
        try await database.saveContacts([contact])
        try await database.syncEngine.sendChanges()
        
        // Remember the initial creation date of the contact record for later.
        guard let originalRecordCreationDate = await database.appData.contacts[contact.id]?.lastKnownRecord?.creationDate else {
            XCTFail("Failed to get original creation date for contact record")
            return
        }
        
        // Delete the record on the side to make it look like another device deleted it.
        try await database.syncEngine.database.deleteRecord(withID: contact.recordID)
        
        // Now make a change to the contact and try to upload it.
        contact.name = "I am a renamed contact!"
        contact.userModificationDate = Date()
        try await database.saveContacts([contact])
        
        // The first time we try to save, we'll get an .unknownItem error.
        // We should make sure we properly discarded the last known record system fields.
        do {
            try await database.syncEngine.sendChanges()
            XCTFail("Did not expect to succeed in sending changes")
        } catch {
            // Success! We expected to fail!
        }
        let lastKnownRecordAfterZoneNotFound = await database.appData.contacts[contact.id]?.lastKnownRecord
        XCTAssertNil(lastKnownRecordAfterZoneNotFound)
        
        // Now let's try to save again, and it should succeed.
        try await database.syncEngine.sendChanges()
        
        // Now try fetching the contact on another device and make sure we got the new name.
        let databaseB = self.newTestDatabase()
        try await databaseB.syncEngine.fetchChanges()
        guard let contactB = await databaseB.appData.contacts[contact.id] else {
            XCTFail("Failed to get contact on second device")
            return
        }
        let recordCreationDateAfterSave = try XCTUnwrap(contactB.lastKnownRecord?.creationDate)
        XCTAssertNotEqual(recordCreationDateAfterSave, originalRecordCreationDate)
        XCTAssertEqual(contact, contactB)
    }
    
    // MARK: Conflicts
    
    func testSaveFailure_conflict_winnerSavesFirst() async throws {
        try await self.testSaveFailure_conflict(winnerSavesFirst: true)
    }
    
    func testSaveFailure_conflict_winnerSavesLast() async throws {
        try await self.testSaveFailure_conflict(winnerSavesFirst: false)
    }
    
    /// Tests to make sure we properly handle conflicts (`.serverRecordChanged` errors).
    /// The winner of a conflict is the one with the later `userModificationDate`.
    ///
    /// It's possible that the device with the winning value will save _after_ the other device.
    /// For example:
    ///
    /// 1. DeviceA has no network connection.
    /// 2. User modifies data on DeviceA.
    /// 3. An hour later, user modifies data on DeviceB.
    /// 4. DeviceB uploads the change.
    /// 5. DeviceA connects to the network and uploads its change.
    ///
    /// In this case, the value from DeviceB should win even though DeviceA saved to the server last.
    func testSaveFailure_conflict(winnerSavesFirst: Bool) async throws {
        
        // Start out with two devices. Device A will have the winning value.
        let databaseA = self.newTestDatabase()
        let databaseB = self.newTestDatabase()
        
        // Save the initial version from DeviceA.
        var contactA = Contact(name: "A1", userModificationDate: Date())
        let contactID = contactA.id
        try await databaseA.saveContacts([contactA])
        try await databaseA.syncEngine.sendChanges()
        
        // Fetch changes on DeviceB to get in sync.
        try await databaseB.syncEngine.fetchChanges()
        let allContactsB = await databaseB.appData.contacts
        XCTAssertEqual(allContactsB.count, 1)
        var contactB = try XCTUnwrap(allContactsB[contactID])
        XCTAssertEqual(contactB.name, "A1")
        
        // Make a modification locally on both devices.
        let losingModificationDate = Date.now
        let winningModificationDate = Date.now + 1
        contactA.name = "A2"
        contactA.userModificationDate = winningModificationDate
        try await databaseA.saveContacts([contactA])
        contactB.name = "B1"
        contactB.userModificationDate = losingModificationDate
        try await databaseB.saveContacts([contactB])
        
        // Now try to save the changes from both devices.
        // The end result of this operation depends on which device saves first.
        // For example, DeviceB is supposed to lose the conflict.
        // However, if it sends changes first, it won't get the expected value until after it fetches changes.
        
        if winnerSavesFirst {
            try await databaseA.syncEngine.sendChanges()
            do {
                try await databaseB.syncEngine.sendChanges()
                XCTFail("Did not expect to succeed in sending changes")
            } catch {
                // Failure is a great success.
            }
            
            // DeviceB should have gotten a .serverRecordChanged, and it will try to save again.
            let stateA = await databaseA.syncEngine.state
            XCTAssertEqual(stateA.pendingRecordZoneChanges.count, 0)
            let stateB = await databaseB.syncEngine.state
            XCTAssertEqual(stateB.pendingRecordZoneChanges.count, 1)
        } else {
            try await databaseB.syncEngine.sendChanges()
            do {
                try await databaseA.syncEngine.sendChanges()
                XCTFail("Did not expect to succeed in sending changes")
            } catch {
                // Failing is expected.
            }
            
            // DeviceA should have gotten a .serverRecordChanged, and it will try to save again.
            let stateA = await databaseA.syncEngine.state
            XCTAssertEqual(stateA.pendingRecordZoneChanges.count, 1)
            let stateB = await databaseB.syncEngine.state
            XCTAssertEqual(stateB.pendingRecordZoneChanges.count, 0)
        }
        
        // Let's make sure the data in the database matches what we expect.
        // This depends on which device saves first.
        let expectedContactAfterSaveA: Contact
        let expectedContactAfterSaveB: Contact
        if winnerSavesFirst {
            expectedContactAfterSaveA = contactA
            expectedContactAfterSaveB = contactA
        } else {
            expectedContactAfterSaveA = contactA
            expectedContactAfterSaveB = contactB
        }
        
        guard let contactAfterSaveA = await databaseA.appData.contacts[contactID],
              let contactAfterSaveB = await databaseB.appData.contacts[contactID] else {
            XCTFail("Failed to get contacts after conflict")
            return
        }
        XCTAssertEqual(contactAfterSaveA, expectedContactAfterSaveA)
        XCTAssertEqual(contactAfterSaveB, expectedContactAfterSaveB)
        
        // Now whichever device saved second will think it needs to save to the server again.
        // Let's give it a chance to do that, and let's fetch changes on the other device.
        if winnerSavesFirst {
            try await databaseB.syncEngine.sendChanges()
            try await databaseA.syncEngine.fetchChanges()
        } else {
            try await databaseA.syncEngine.sendChanges()
            try await databaseB.syncEngine.fetchChanges()
        }
        
        // Now we should be in a stable state.
        // Let's make sure the data matches what we expect.
        guard let finalContactA = await databaseA.appData.contacts[contactID],
              let finalContactB = await databaseB.appData.contacts[contactID] else {
            XCTFail("Failed to get final contacts after quiescing")
            return
        }
        
        // We expect the value from DeviceA to win in the end.
        let expectedFinalContact = contactA
        XCTAssertEqual(finalContactA, expectedFinalContact)
        XCTAssertEqual(finalContactB, expectedFinalContact)
    }
    
    // TODO: More tests!
    //
    // When writing your app, you should try to cover as many edge cases as possible in your tests.
    // For example:
    //
    // - Test deleting a contact.
    // - Test deleting a contact while another device modifies that contact.
    
    // MARK: - Helpers
    
    func newTestDatabase() -> SyncedDatabase {
        // Create a new database with a completely separate file on disk.
        // Each separate local store will sync with the same cloud database.
        // This allows us to pretend we have separate devices syncing with one another.
        let dataURL = FileManager.default.temporaryDirectory.appending(component: "Contacts-\(UUID().uuidString)").appendingPathExtension("json")
        let database = SyncedDatabase(automaticallySync: false, dataURL: dataURL)
        return database
    }
}
