import Foundation
import HavenCore
import Contacts
import CommonCrypto
import HostAgentEmail
#if canImport(Darwin)
import Darwin
#endif

/// Handler for Contacts collector endpoints
public actor ContactsHandler {
    private let config: HavenConfig
    private let gatewayClient: GatewayClient
    private let logger = HavenLogger(category: "contacts-handler")
    
    // State tracking
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunStats: CollectorStats?
    private var lastRunError: String?
    
    private struct CollectorStats: Codable {
        var contactsScanned: Int
        var contactsProcessed: Int
        var contactsSubmitted: Int
        var contactsSkipped: Int
        var batchesSubmitted: Int
        var startTime: Date
        var endTime: Date?
        var durationMs: Int?
        
        var toDict: [String: Any] {
            var dict: [String: Any] = [
                "contacts_scanned": contactsScanned,
                "contacts_processed": contactsProcessed,
                "contacts_submitted": contactsSubmitted,
                "contacts_skipped": contactsSkipped,
                "batches_submitted": batchesSubmitted,
                "start_time": ISO8601DateFormatter().string(from: startTime)
            ]
            if let endTime = endTime {
                dict["end_time"] = ISO8601DateFormatter().string(from: endTime)
            }
            if let durationMs = durationMs {
                dict["duration_ms"] = durationMs
            }
            return dict
        }
    }
    
    public init(config: HavenConfig, gatewayClient: GatewayClient) {
        self.config = config
        self.gatewayClient = gatewayClient
    }
    
    /// Handle POST /v1/collectors/contacts:run
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Check if already running
        guard !isRunning else {
            logger.warning("Contacts collector already running")
            return HTTPResponse(
                statusCode: 409,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Collector is already running"}"#.data(using: .utf8)
            )
        }
        
        // Parse request
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        var runRequest: CollectorRunRequest?
        var mode: CollectorRunRequest.Mode = .real
        var limit: Int? = nil
        
        if let body = request.body, !body.isEmpty {
            do {
                runRequest = try decoder.decode(CollectorRunRequest.self, from: body)
                mode = runRequest?.mode ?? .real
                limit = runRequest?.limit
            } catch {
                logger.error("Failed to decode CollectorRunRequest", metadata: ["error": error.localizedDescription])
                return HTTPResponse.badRequest(message: "Invalid request format: \(error.localizedDescription)")
            }
        }
        
        logger.info("Starting Contacts collector", metadata: [
            "mode": mode.rawValue,
            "limit": limit?.description ?? "unlimited"
        ])
        
        // Run collection
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        lastRunError = nil
        
        let startTime = Date()
        var stats = CollectorStats(
            contactsScanned: 0,
            contactsProcessed: 0,
            contactsSubmitted: 0,
            contactsSkipped: 0,
            batchesSubmitted: 0,
            startTime: startTime
        )
        
        do {
            let result = try await collectContacts(mode: mode, limit: limit, stats: &stats)
            
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "completed"
            lastRunStats = stats
            
            logger.info("Contacts collection completed", metadata: [
                "scanned": String(stats.contactsScanned),
                "submitted": String(stats.contactsSubmitted),
                "batches": String(stats.batchesSubmitted),
                "duration_ms": String(stats.durationMs ?? 0)
            ])
            
            // Return adapter format that RunRouter expects
            return encodeAdapterResponse(
                scanned: stats.contactsScanned,
                matched: stats.contactsProcessed,
                submitted: stats.contactsSubmitted,
                skipped: stats.contactsSkipped,
                earliestTouched: nil,
                latestTouched: nil,
                warnings: result.warnings,
                errors: result.errors
            )
            
        } catch {
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "failed"
            lastRunStats = stats
            lastRunError = error.localizedDescription
            
            logger.error("Contacts collection failed", metadata: ["error": error.localizedDescription])
            
            return HTTPResponse.internalError(message: "Collection failed: \(error.localizedDescription)")
        }
    }
    
    /// Handle GET /v1/collectors/contacts/state
    public func handleState(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        var state: [String: Any] = [
            "is_running": isRunning,
            "last_run_status": lastRunStatus
        ]
        
        if let lastRunTime = lastRunTime {
            state["last_run_time"] = ISO8601DateFormatter().string(from: lastRunTime)
        }
        
        if let lastRunStats = lastRunStats {
            state["last_run_stats"] = lastRunStats.toDict
        }
        
        if let lastRunError = lastRunError {
            state["last_run_error"] = lastRunError
        }
        
        // Load persisted state from file
        if let persistedState = loadPersistedState() {
            state["persisted_state"] = persistedState
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            return HTTPResponse.internalError(message: "Failed to encode state: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Collection Logic
    
    private struct CollectionResult {
        let warnings: [String]
        let errors: [String]
    }
    
    private func collectContacts(mode: CollectorRunRequest.Mode, limit: Int?, stats: inout CollectorStats) async throws -> CollectionResult {
        var warnings: [String] = []
        var errors: [String] = []
        
        // In simulate mode, return mock data
        if mode == .simulate {
            logger.info("Running in simulate mode - returning mock contacts")
            let mockContacts = generateMockContacts(limit: limit ?? 5)
            stats.contactsScanned = mockContacts.count
            stats.contactsProcessed = mockContacts.count
            stats.contactsSubmitted = mockContacts.count
            
            // Still post to gateway in simulate mode (but gateway should handle it appropriately)
            try await submitContactsToGateway(contacts: mockContacts, stats: &stats)
            
            return CollectionResult(warnings: warnings, errors: errors)
        }
        
        // Real mode: access macOS Contacts
        let contacts: [CNContact]
        do {
            contacts = try fetchContacts(limit: limit)
        } catch {
            let errorMsg = "Failed to fetch contacts: \(error.localizedDescription)"
            logger.error(errorMsg)
            errors.append(errorMsg)
            throw ContactsError.contactAccessFailed(errorMsg)
        }
        
        stats.contactsScanned = contacts.count
        
        // Convert CNContact to PersonPayloadModel
        var people: [PersonPayloadModel] = []
        for contact in contacts {
            do {
                let person = try convertContactToPerson(contact: contact)
                people.append(person)
                stats.contactsProcessed += 1
            } catch {
                let errorMsg = "Failed to convert contact: \(error.localizedDescription)"
                logger.warning("contact_conversion_failed", metadata: [
                    "error": error.localizedDescription,
                    "identifier": contact.identifier
                ])
                warnings.append(errorMsg)
                stats.contactsSkipped += 1
                continue
            }
        }
        
        // Submit to gateway
        try await submitContactsToGateway(contacts: people, stats: &stats)
        stats.contactsSubmitted = people.count
        
        // Persist state
        savePersistedState(scanned: stats.contactsScanned, submitted: stats.contactsSubmitted)
        
        return CollectionResult(warnings: warnings, errors: errors)
    }
    
    private func fetchContacts(limit: Int?) throws -> [CNContact] {
        let store = CNContactStore()
        
        // Request authorization if needed
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard authStatus == .authorized else {
            throw ContactsError.contactAccessDenied("Contacts access denied. Status: \(authStatus.rawValue)")
        }
        
        // Define keys to fetch
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]
        
        let request = CNContactFetchRequest(keysToFetch: keys)
        var contacts: [CNContact] = []
        
        try store.enumerateContacts(with: request) { contact, stop in
            contacts.append(contact)
            
            if let limit = limit, contacts.count >= limit {
                stop.pointee = true
            }
        }
        
        return contacts
    }
    
    private func convertContactToPerson(contact: CNContact) throws -> PersonPayloadModel {
        let identifier = contact.identifier
        let givenName = contact.givenName.isEmpty ? nil : contact.givenName
        let familyName = contact.familyName.isEmpty ? nil : contact.familyName
        let organization = contact.organizationName.isEmpty ? nil : contact.organizationName
        
        // Build display name
        var displayName = ""
        if let given = givenName, let family = familyName {
            displayName = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
        } else if let given = givenName {
            displayName = given
        } else if let family = familyName {
            displayName = family
        }
        
        if displayName.isEmpty {
            displayName = organization ?? identifier
        }
        
        // Convert phone numbers
        var phones: [ContactValueModel] = []
        for phone in contact.phoneNumbers {
            let label = localizedLabel(for: phone.label)
            let value = phone.value.stringValue
            phones.append(ContactValueModel(
                value: value,
                value_raw: value,
                label: label
            ))
        }
        
        // Convert email addresses
        var emails: [ContactValueModel] = []
        for email in contact.emailAddresses {
            let label = localizedLabel(for: email.label)
            let value = email.value as String
            emails.append(ContactValueModel(
                value: value,
                value_raw: value,
                label: label
            ))
        }
        
        // Convert URLs
        var urls: [ContactUrlModel] = []
        for url in contact.urlAddresses {
            let label = localizedLabel(for: url.label)
            let value = url.value as String
            urls.append(ContactUrlModel(
                label: label,
                url: value
            ))
        }
        
        // Convert addresses
        var addresses: [ContactAddressModel] = []
        for address in contact.postalAddresses {
            let label = localizedLabel(for: address.label)
            let addr = address.value
            addresses.append(ContactAddressModel(
                label: label,
                street: addr.street.isEmpty ? nil : addr.street,
                city: addr.city.isEmpty ? nil : addr.city,
                region: addr.state.isEmpty ? nil : addr.state,
                postal_code: addr.postalCode.isEmpty ? nil : addr.postalCode,
                country: addr.country.isEmpty ? nil : addr.country
            ))
        }
        
        // Convert nicknames
        let nicknames = contact.nickname.isEmpty ? [] : [contact.nickname]
        
        // Compute photo hash
        let photoHash = contact.imageData.map { data in
            sha256(data: data)
        }
        
        return PersonPayloadModel(
            external_id: identifier,
            display_name: displayName,
            given_name: givenName,
            family_name: familyName,
            organization: organization,
            nicknames: nicknames,
            notes: nil,
            photo_hash: photoHash,
            emails: emails,
            phones: phones,
            addresses: addresses,
            urls: urls
        )
    }
    
    private func localizedLabel(for label: String?) -> String? {
        guard let label = label else { return "other" }
        
        // Use CNLabeledValue.localizedString(forLabel:) to get localized label
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: label)
        return localized.isEmpty ? label : localized
    }
    
    private func sha256(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func submitContactsToGateway(contacts: [PersonPayloadModel], stats: inout CollectorStats) async throws {
        guard !contacts.isEmpty else {
            logger.info("No contacts to submit")
            return
        }
        
        // Get batch size from config or environment
        let batchSize = getBatchSize()
        
        // Submit in batches
        for i in stride(from: 0, to: contacts.count, by: batchSize) {
            let endIndex = min(i + batchSize, contacts.count)
            let batch = Array(contacts[i..<endIndex])
            
            try await submitBatch(batch: batch)
            stats.batchesSubmitted += 1
            
            logger.debug("Submitted batch", metadata: [
                "batch_size": String(batch.count),
                "batch_index": String(stats.batchesSubmitted)
            ])
        }
    }
    
    private func submitBatch(batch: [PersonPayloadModel]) async throws {
        let url = URL(string: config.gateway.baseUrl + "/catalog/contacts/ingest")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.auth.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = TimeInterval(config.gateway.timeout)
        
        // Build payload
        let deviceId = getDeviceId()
        let payload: [String: Any] = [
            "source": "macos_contacts",
            "device_id": deviceId,
            "batch_id": UUID().uuidString,
            "since_token": NSNull(),
            "people": batch.map { person in
                personToDict(person: person)
            }
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        
        logger.debug("Posting contacts batch to gateway", metadata: [
            "count": String(batch.count),
            "url": url.absoluteString
        ])
        
        // Send with retry logic
        let maxRetries = 5
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ContactsError.invalidGatewayResponse
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw ContactsError.gatewayHttpError(httpResponse.statusCode, body)
                }
                
                // Parse response
                if let responseObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    logger.debug("Gateway response", metadata: [
                        "accepted": String(responseObj["accepted"] as? Int ?? 0),
                        "upserts": String(responseObj["upserts"] as? Int ?? 0)
                    ])
                }
                
                logger.debug("Batch posted successfully")
                return
                
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delay = min(Double(attempt) * 0.5, 5.0) // Exponential backoff, max 5s
                    logger.warning("Batch submission failed, retrying", metadata: [
                        "attempt": String(attempt),
                        "max_retries": String(maxRetries),
                        "error": error.localizedDescription
                    ])
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        // All retries failed
        if let error = lastError {
            logger.error("Failed to submit batch after retries", metadata: ["error": error.localizedDescription])
            throw error
        }
    }
    
    private func personToDict(person: PersonPayloadModel) -> [String: Any] {
        var dict: [String: Any] = [
            "external_id": person.external_id,
            "display_name": person.display_name,
            "nicknames": person.nicknames,
            "emails": person.emails.map { email in
                [
                    "value": email.value,
                    "value_raw": email.value_raw as Any,
                    "label": email.label as Any
                ]
            },
            "phones": person.phones.map { phone in
                [
                    "value": phone.value,
                    "value_raw": phone.value_raw as Any,
                    "label": phone.label as Any
                ]
            },
            "addresses": person.addresses.map { addr in
                [
                    "label": addr.label as Any,
                    "street": addr.street as Any,
                    "city": addr.city as Any,
                    "region": addr.region as Any,
                    "postal_code": addr.postal_code as Any,
                    "country": addr.country as Any
                ]
            },
            "urls": person.urls.map { url in
                [
                    "label": url.label as Any,
                    "url": url.url as Any
                ]
            }
        ]
        
        if let givenName = person.given_name {
            dict["given_name"] = givenName
        }
        if let familyName = person.family_name {
            dict["family_name"] = familyName
        }
        if let organization = person.organization {
            dict["organization"] = organization
        }
        if let notes = person.notes {
            dict["notes"] = notes
        }
        if let photoHash = person.photo_hash {
            dict["photo_hash"] = photoHash
        }
        
        return dict
    }
    
    private func generateMockContacts(limit: Int) -> [PersonPayloadModel] {
        let names = [
            ("John", "Doe", "jdoe@example.com", "555-0100"),
            ("Jane", "Smith", "jsmith@example.com", "555-0101"),
            ("Bob", "Johnson", "bjohnson@example.com", "555-0102"),
            ("Alice", "Williams", "awilliams@example.com", "555-0103"),
            ("Charlie", "Brown", "cbrown@example.com", "555-0104")
        ]
        
        return names.prefix(limit).enumerated().map { index, name in
            PersonPayloadModel(
                external_id: "mock-\(index)",
                display_name: "\(name.0) \(name.1)",
                given_name: name.0,
                family_name: name.1,
                organization: nil,
                nicknames: [],
                notes: nil,
                photo_hash: nil,
                emails: [ContactValueModel(value: name.2, value_raw: name.2, label: "work")],
                phones: [ContactValueModel(value: name.3, value_raw: name.3, label: "mobile")],
                addresses: [],
                urls: []
            )
        }
    }
    
    private func getBatchSize() -> Int {
        if let envValue = ProcessInfo.processInfo.environment["CONTACTS_BATCH_SIZE"],
           let size = Int(envValue), size > 0 {
            return size
        }
        return 500 // Default
    }
    
    private func getDeviceId() -> String {
        if let deviceId = ProcessInfo.processInfo.environment["CONTACTS_DEVICE_ID"], !deviceId.isEmpty {
            return deviceId
        }
        // Try to get hostname from system
        var hostnameBuffer = [Int8](repeating: 0, count: 256)
        if gethostname(&hostnameBuffer, hostnameBuffer.count) == 0 {
            let hostname = String(cString: hostnameBuffer)
            if !hostname.isEmpty {
                return hostname
            }
        }
        return "unknown-device"
    }
    
    // MARK: - State Persistence
    
    private func stateFilePath() -> URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let havenDir = homeDir.appendingPathComponent(".haven")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        
        return havenDir.appendingPathComponent("contacts_collector_state.json")
    }
    
    private func savePersistedState(scanned: Int, submitted: Int) {
        let state: [String: Any] = [
            "last_scanned_count": scanned,
            "last_submitted_count": submitted,
            "last_updated": ISO8601DateFormatter().string(from: Date())
        ]
        
        let filePath = stateFilePath()
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
            try? data.write(to: filePath)
            logger.debug("Persisted state", metadata: ["path": filePath.path])
        }
    }
    
    private func loadPersistedState() -> [String: Any]? {
        let filePath = stateFilePath()
        guard let data = try? Data(contentsOf: filePath) else {
            return nil
        }
        
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    
    // MARK: - Adapter Response Encoding
    
    private func encodeAdapterResponse(
        scanned: Int,
        matched: Int,
        submitted: Int,
        skipped: Int,
        earliestTouched: String?,
        latestTouched: String?,
        warnings: [String],
        errors: [String]
    ) -> HTTPResponse {
        var payload: [String: Any] = [
            "scanned": scanned,
            "matched": matched,
            "submitted": submitted,
            "skipped": skipped,
            "batches": 0,
            "warnings": warnings,
            "errors": errors
        ]
        
        if let earliest = earliestTouched {
            payload["earliest_touched"] = earliest
        }
        if let latest = latestTouched {
            payload["latest_touched"] = latest
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            return HTTPResponse.internalError(message: "Failed to encode response: \(error.localizedDescription)")
        }
    }
}

// MARK: - Error Types

enum ContactsError: Error, LocalizedError {
    case contactAccessDenied(String)
    case contactAccessFailed(String)
    case invalidGatewayResponse
    case gatewayHttpError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .contactAccessDenied(let message):
            return "Contacts access denied: \(message)"
        case .contactAccessFailed(let message):
            return "Failed to access contacts: \(message)"
        case .invalidGatewayResponse:
            return "Invalid gateway response"
        case .gatewayHttpError(let code, let body):
            return "Gateway HTTP error \(code): \(body)"
        }
    }
}

// MARK: - PersonPayloadModel

// Note: These structs should match the gateway API schema
// For now, we'll define them here. In the future, these could be generated from OpenAPI schema

struct PersonPayloadModel {
    let external_id: String
    let display_name: String
    let given_name: String?
    let family_name: String?
    let organization: String?
    let nicknames: [String]
    let notes: String?
    let photo_hash: String?
    let emails: [ContactValueModel]
    let phones: [ContactValueModel]
    let addresses: [ContactAddressModel]
    let urls: [ContactUrlModel]
}

struct ContactValueModel {
    let value: String
    let value_raw: String?
    let label: String?
}

struct ContactAddressModel {
    let label: String?
    let street: String?
    let city: String?
    let region: String?
    let postal_code: String?
    let country: String?
}

struct ContactUrlModel {
    let label: String?
    let url: String?
}

