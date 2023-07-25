# CloudKit Samples: CKSyncEngine

### Goals

This project demonstrates using `CKSyncEngine` to sync data in an app.

### Prerequisites

* A Mac with [Xcode 15 beta 5](https://developer.apple.com/xcode/) (or later) installed is required to build and test this project.
* An iOS device running iOS 17 beta 4 or later, or Mac running macOS 14 beta 4 or later, is required to run this app.
* An active [Apple Developer Program membership](https://developer.apple.com/support/compare-memberships/) is needed to create a CloudKit container and sign the app to run on a device.

**Note**: `CKSyncEngine` relies on remote notifications in order to sync properly. Simulators cannot register for remote push notifications, so running this sample on a real device or Mac is required for this app to properly sync.

### Setup Instructions

1. Ensure you are logged into your developer account in Xcode with an active membership.
1. In the “Signing & Capabilities” tab of the SyncEngine target, ensure your team is selected in the Signing section, and there is a valid container selected under the “iCloud” section.
1. Ensure that all devices are logged into the same iCloud account.

#### Using Your Own iCloud Container

* Create a new iCloud container through Xcode’s “Signing & Capabilities” tab of the SyncEngine app target.
* Update the `CKContainer` in [SyncedDatabase.swift](SyncEngine/SyncedDatabase.swift) with your new iCloud container identifier.

### How it Works

* The main `CKSyncEngine` integration is contained in [SyncedDatabase.swift](SyncEngine/SyncedDatabase.swift).
* On first launch, the app initializes a `SyncedDatabase`, which syncs a local store with the server.
* The app’s main UI displays a list of Contacts. When the user adds a new Contact through the UI, this contact is saved to a local store and to the server.
* Saving the Contact record triggers a push notification, which tells other devices to fetch the record from the server.
* When other devices fetch the record, they save them to the local store, and the UI shows the new data.

### Example Flow

1. Run the app on a device or Mac. Latest changes are fetched from the server.
1. Repeat the above on another device and add a new contact through the UI.
1. The first device fetches the changes and shows the contact in the UI.

### Tests

This project includes a few basic tests for `CKSyncEngine` integration in [SyncTests.swift](Tests/SyncTests.swift). This shows one possible way to test your CloudKit sync code by simulating multiple devices syncing back and forth. The test suite only exercises a few basic scenarios, and there are many more complex scenarios to test in your own application.

### Things To Learn

* Syncing data with `CKSyncEngine`.
* Adding, deleting, and merging remote changes into a local store, and reflecting those changes live in a UI.
* Testing your integration with `CKSyncEngine`.

### Further Reading

* [CKSyncEngine Documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine)
