//
//  ContactsList.swift
//  SyncEngine
//

import os.log
import SwiftUI

struct ContactsList: View {
    
    @EnvironmentObject var database: SyncedDatabase
    
    // The array of contacts we show in the list.
    var sortedContacts: [Contact] { self.database.viewModel.contacts.values.sorted(by: <) }
    
    // The set of selected contacts. Note that this is the value for `Contact.listID`, not `Contact.id`.
    @State private var selection = Set<String>()
    
    // Used to focus the text field when adding a new contact.
    @FocusState private var newlyCreatedContactID: Contact.ID?
    
    var body: some View {
        
        List(selection: self.$selection) {
            
            ForEach(self.sortedContacts, id: \.listID) { contact in
                
                ContactView(contact: contact)
                    .environmentObject(self.database)
                    .focused(self.$newlyCreatedContactID, equals: contact.id)
            }
            .onDelete { indexSet in
                let contactIDsToDelete = indexSet.map { self.sortedContacts[$0].id }
                self.deleteContacts(contactIDsToDelete)
            }
        }
        .toolbar {
            HStack {
                Button("Delete Server Data") {
                    Task {
                        try await self.database.deleteServerData()
                    }
                }
                
                Button("Delete Local Data") {
                    Task {
                        try await self.database.deleteLocalData()
                    }
                }
                
                Button(action: {
                    self.addNewContact()
                }, label: {
                    Image(systemName: "plus")
                })
                .keyboardShortcut("N")
            }
        }
#if os(macOS)
        .onDeleteCommand {
            let contactIDs = self.selection.compactMap { Contact.contactID(from: $0) }
            self.deleteContacts(Array(contactIDs))
        }
#endif
    }
    
    func addNewContact() {
        let contact = Contact(userModificationDate: .now)
        Task {
            // This error should be handled, but we'll skip that for brevity in this sample app.
            try? await self.database.saveContacts([contact])
            
            await MainActor.run {
                self.newlyCreatedContactID = contact.id
            }
        }
    }
    
    func deleteContacts(_ ids: [Contact.ID]) {
        Task {
            // This error should be handled, but we'll skip that for brevity in this sample app.
            try? await self.database.deleteContacts(ids)
        }
    }
}

struct ContactView: View {
    
    @EnvironmentObject var database: SyncedDatabase
    
    @State var contact: Contact
    
    var body: some View {
        
        TextField("Name", text: self.$contact.name)
            .onSubmit {
                // The name from the text field is already bound to the Contact object.
                // We just need to set the user modification date and save it to the database.
                self.contact.userModificationDate = Date()
                
                Task {
                    // This error should be handled, but we'll skip that for brevity in this sample app.
                    try? await self.database.saveContacts([self.contact])
                }
            }
    }
}

extension Contact {
    
    // In order for the list to update properly when fetch changes from the cloud, we need to use something other than the contact ID for the list item ID.
    var listID: String { "\(self.id)\(Self.listIDSeparator)\(self.userModificationDate)" }
    
    static let listIDSeparator = "::"
    
    static func contactID(from listID: String) -> Contact.ID? {
        if let separatorRange = listID.firstRange(of: Self.listIDSeparator) {
            let id = listID.prefix(upTo: separatorRange.lowerBound)
            return String(id)
        } else {
            Logger.ui.error("Couldn't find separator in list ID: \(listID)")
            return nil
        }
    }
}
