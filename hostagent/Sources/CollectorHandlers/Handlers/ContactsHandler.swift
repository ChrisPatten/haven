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
    private var runRequest: CollectorRunRequest?
    
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
    
    // MARK: - Direct Swift APIs
    
    /// Direct Swift API for running the Contacts collector
    /// Replaces HTTP-based handleRun for in-app integration
    public func runCollector(
        request: CollectorRunRequest?,
        onProgress: ((Int, Int, Int, Int) -> Void)? = nil
    ) async throws -> RunResponse {
        // Check if already running
        guard !isRunning else {
            throw ContactsError.contactAccessFailed("Collector is already running")
        }
        
        // Parse request
        let mode: CollectorRunRequest.Mode = request?.mode ?? .real
        let limit = request?.limit
        
        // Store request for access in collectContacts
        self.runRequest = request
        
        logger.info("Starting Contacts collector", metadata: [
            "mode": mode.rawValue,
            "limit": limit?.description ?? "unlimited"
        ])
        
        // Initialize response
        let runID = UUID().uuidString
        let startTime = Date()
        var response = RunResponse(collector: "contacts", runID: runID, startedAt: startTime)
        
        // Run collection
        isRunning = true
        lastRunTime = startTime
        lastRunStatus = "running"
        lastRunError = nil
        
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
            lastRunStatus = "ok"
            lastRunStats = stats
            
            logger.info("Contacts collection completed", metadata: [
                "scanned": String(stats.contactsScanned),
                "submitted": String(stats.contactsSubmitted),
                "batches": String(stats.batchesSubmitted),
                "duration_ms": String(stats.durationMs ?? 0)
            ])
            
            // Convert stats to RunResponse
            response.finish(status: .ok, finishedAt: endTime)
            response.stats = RunResponse.Stats(
                scanned: stats.contactsScanned,
                matched: stats.contactsProcessed,
                submitted: stats.contactsSubmitted,
                skipped: stats.contactsSkipped,
                earliest_touched: nil,
                latest_touched: nil,
                batches: stats.batchesSubmitted
            )
            response.warnings = result.warnings
            response.errors = result.errors
            
            // Report final progress
            onProgress?(stats.contactsScanned, stats.contactsProcessed, stats.contactsSubmitted, stats.contactsSkipped)
            
            return response
            
        } catch {
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "failed"
            lastRunStats = stats
            lastRunError = error.localizedDescription
            
            logger.error("Contacts collection failed", metadata: ["error": error.localizedDescription])
            
            response.finish(status: .error, finishedAt: endTime)
            response.errors = [error.localizedDescription]
            
            throw error
        }
    }
    
    /// Direct Swift API for getting collector state
    /// Replaces HTTP-based handleState for in-app integration
    public func getCollectorState() async -> CollectorStateInfo {
        // Convert lastRunStats to [String: HavenCore.AnyCodable]
        var statsDict: [String: HavenCore.AnyCodable]? = nil
        if let stats = lastRunStats {
            var dict: [String: HavenCore.AnyCodable] = [:]
            let statsDictAny = stats.toDict
            for (key, value) in statsDictAny {
                dict[key] = HavenCore.AnyCodable(value)
            }
            statsDict = dict
        }
        
        return CollectorStateInfo(
            isRunning: isRunning,
            lastRunTime: lastRunTime,
            lastRunStatus: lastRunStatus,
            lastRunStats: statsDict,
            lastRunError: lastRunError
        )
    }
    
    // MARK: - Collection Logic
    
    private struct CollectionResult {
        let warnings: [String]
        let errors: [String]
    }
    
    private func collectContacts(mode: CollectorRunRequest.Mode, limit: Int?, stats: inout CollectorStats) async throws -> CollectionResult {
        var warnings: [String] = []
        var errors: [String] = []
        
        // Check if a VCF directory was specified in scope
        let scopeDict = runRequest?.scope?.value as? [String: Any] ?? [:]
        let vcfDirectory = scopeDict["vcf_directory"] as? String
        
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
        
        // Real mode: check for VCF directory first, otherwise access macOS Contacts
        var people: [PersonPayloadModel] = []
        
        if let vcfDir = vcfDirectory, !vcfDir.isEmpty {
            logger.info("Loading contacts from VCF directory", metadata: ["directory": vcfDir])
            do {
                people = try loadContactsFromVCFDirectory(path: vcfDir, limit: limit)
                stats.contactsScanned = people.count
                stats.contactsProcessed = people.count
            } catch {
                let errorMsg = "Failed to load VCF contacts: \(error.localizedDescription)"
                logger.error(errorMsg)
                errors.append(errorMsg)
                throw ContactsError.vcfLoadFailed(errorMsg)
            }
        } else {
            // Use macOS Contacts
            let contacts: [CNContact]
            do {
                contacts = try await fetchContacts(limit: limit)
            } catch {
                let errorMsg = "Failed to fetch contacts: \(error.localizedDescription)"
                logger.error(errorMsg)
                errors.append(errorMsg)
                throw ContactsError.contactAccessFailed(errorMsg)
            }
            
            stats.contactsScanned = contacts.count
            
            // Convert CNContact to PersonPayloadModel
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
        }
        
        // Submit to gateway
        try await submitContactsToGateway(contacts: people, stats: &stats)
        stats.contactsSubmitted = people.count
        
        // Persist state
        savePersistedState(scanned: stats.contactsScanned, submitted: stats.contactsSubmitted)
        
        return CollectionResult(warnings: warnings, errors: errors)
    }
    
    private func fetchContacts(limit: Int?) async throws -> [CNContact] {
        let store = CNContactStore()
        
        // Check current authorization status
        var authStatus = CNContactStore.authorizationStatus(for: .contacts)
        
        // Request authorization if not determined
        if authStatus == .notDetermined {
            logger.info("Requesting Contacts permission")
            do {
                let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    store.requestAccess(for: .contacts) { granted, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
                if granted {
                    authStatus = .authorized
                    logger.info("Contacts permission granted")
                } else {
                    authStatus = .denied
                    logger.warning("Contacts permission denied by user")
                }
            } catch {
                logger.error("Failed to request Contacts permission", metadata: ["error": error.localizedDescription])
                throw ContactsError.contactAccessFailed("Failed to request Contacts permission: \(error.localizedDescription)")
            }
        }
        
        // Check if authorized
        guard authStatus == .authorized else {
            let statusDescription: String
            switch authStatus {
            case .notDetermined:
                statusDescription = "not determined"
            case .denied:
                statusDescription = "denied - please grant Contacts access in System Settings"
            case .restricted:
                statusDescription = "restricted by parental controls"
            case .authorized:
                statusDescription = "authorized" // Should not reach here
            @unknown default:
                statusDescription = "unknown (\(authStatus.rawValue))"
            }
            throw ContactsError.contactAccessDenied("Contacts access denied. Status: \(statusDescription). Please grant Contacts permission in System Settings → Privacy & Security → Contacts.")
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
    
    // MARK: - VCF Loading
    
    private func loadContactsFromVCFDirectory(path: String, limit: Int?) throws -> [PersonPayloadModel] {
        let fileManager = FileManager.default
        
        // Expand ~ to home directory
        let expandedPath = NSString(string: path).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: expandedPath)
        
        // Check if directory exists
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue else {
            throw ContactsError.vcfLoadFailed("VCF directory does not exist: \(expandedPath)")
        }
        
        // Get all VCF files
        let vcfFiles: [URL]
        do {
            let allFiles = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            vcfFiles = allFiles.filter { $0.pathExtension.lowercased() == "vcf" }
        } catch {
            throw ContactsError.vcfLoadFailed("Failed to read VCF directory: \(error.localizedDescription)")
        }
        
        logger.info("Found VCF files", metadata: ["count": String(vcfFiles.count), "directory": expandedPath])
        
        var people: [PersonPayloadModel] = []
        
        for vcfURL in vcfFiles {
            do {
                let fileData = try Data(contentsOf: vcfURL)
                guard let content = String(data: fileData, encoding: .utf8) else {
                    logger.warning("Failed to decode VCF file as UTF-8", metadata: ["file": vcfURL.lastPathComponent])
                    continue
                }
                
                let parsedContacts = try parseVCF(content: content)
                logger.info("Parsed contacts from VCF", metadata: ["file": vcfURL.lastPathComponent, "count": String(parsedContacts.count)])
                
                people.append(contentsOf: parsedContacts)
                
                if let limit = limit, people.count >= limit {
                    people = Array(people.prefix(limit))
                    break
                }
            } catch {
                logger.warning("Failed to parse VCF file", metadata: [
                    "file": vcfURL.lastPathComponent,
                    "error": error.localizedDescription
                ])
                continue
            }
        }
        
        logger.info("Total contacts loaded from VCF", metadata: ["count": String(people.count)])
        return people
    }
    
    private func parseVCF(content: String) throws -> [PersonPayloadModel] {
        var people: [PersonPayloadModel] = []
        
        // Normalize line endings: handle both \r\n and \n
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        var currentVCard: [String: [String]] = [:]
        var inVCard = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.uppercased() == "BEGIN:VCARD" {
                inVCard = true
                currentVCard = [:]
            } else if trimmedLine.uppercased() == "END:VCARD" {
                if inVCard {
                    do {
                        let person = try parseVCardData(currentVCard)
                        people.append(person)
                    } catch {
                        logger.warning("Failed to parse vcard data", metadata: ["error": error.localizedDescription])
                    }
                    inVCard = false
                    currentVCard = [:]
                }
            } else if inVCard && !trimmedLine.isEmpty {
                // Parse VCard property
                parseVCardProperty(line: trimmedLine, into: &currentVCard)
            }
        }
        
        return people
    }
    
    private func parseVCardProperty(line: String, into vcard: inout [String: [String]]) {
        // VCard property parser
        // Format: PROPERTY:value or PROPERTY;PARAM=value;PARAM=value:value
        
        // Handle line folding (continuation lines that start with space/tab)
        let unfoldedLine = line
        
        let parts = unfoldedLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return }
        
        let keyPart = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : ""
        
        // Extract property name (ignore parameters for now)
        let keyComponents = keyPart.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(keyComponents[0]).trimmingCharacters(in: .whitespaces).uppercased()
        
        guard !key.isEmpty && !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        
        if vcard[key] == nil {
            vcard[key] = []
        }
        vcard[key]?.append(value)
    }
    
    private func parseVCardData(_ vcard: [String: [String]]) throws -> PersonPayloadModel {
        var givenName: String? = nil
        var familyName: String? = nil
        var displayName: String? = nil
        var organization: String? = nil
        var nicknames: [String] = []
        var emails: [ContactValueModel] = []
        var phones: [ContactValueModel] = []
        var urls: [ContactUrlModel] = []
        var photoHash: String? = nil
        
        // Parse FN (formatted name)
        if let fn = vcard["FN"]?.first {
            displayName = fn.isEmpty ? nil : fn
        }
        
        // Parse N (name: family;given;middle;prefix;suffix)
        if let n = vcard["N"]?.first {
            let nameParts = n.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            if nameParts.count > 0 && !nameParts[0].isEmpty {
                familyName = nameParts[0]
            }
            if nameParts.count > 1 && !nameParts[1].isEmpty {
                givenName = nameParts[1]
            }
        }
        
        // Parse ORG
        if let org = vcard["ORG"]?.first, !org.isEmpty {
            organization = org
        }
        
        // Parse NICKNAME
        for nick in vcard["NICKNAME"] ?? [] {
            if !nick.isEmpty {
                nicknames.append(nick)
            }
        }
        
        // Parse EMAIL
        for emailLine in vcard["EMAIL"] ?? [] {
            let emailValue = emailLine.trimmingCharacters(in: .whitespaces)
            if !emailValue.isEmpty {
                emails.append(ContactValueModel(
                    value: emailValue,
                    value_raw: emailValue,
                    label: "other"
                ))
            }
        }
        
        // Parse TEL
        for telLine in vcard["TEL"] ?? [] {
            let telValue = telLine.trimmingCharacters(in: .whitespaces)
            if !telValue.isEmpty {
                phones.append(ContactValueModel(
                    value: telValue,
                    value_raw: telValue,
                    label: "other"
                ))
            }
        }
        
        // Parse URL
        for urlLine in vcard["URL"] ?? [] {
            let urlValue = urlLine.trimmingCharacters(in: .whitespaces)
            if !urlValue.isEmpty {
                urls.append(ContactUrlModel(label: "other", url: urlValue))
            }
        }
        
        // Parse PHOTO (base64 encoded)
        if let photoData = vcard["PHOTO"]?.first, !photoData.isEmpty {
            // Try to extract base64 data - typically in format like "data:image/jpeg;base64,xxx"
            if let base64String = extractBase64FromPhoto(photoData),
               let imageData = Data(base64Encoded: base64String) {
                photoHash = sha256(data: imageData)
            }
        }
        
        // Generate external ID
        let externalId: String
        if let fn = displayName {
            externalId = "vcf_\(fn.lowercased().replacingOccurrences(of: " ", with: "_"))"
        } else if let given = givenName, let family = familyName {
            externalId = "vcf_\(given.lowercased())_\(family.lowercased())"
        } else {
            externalId = "vcf_\(UUID().uuidString)"
        }
        
        // Build display name
        let finalDisplayName: String
        if let dn = displayName {
            finalDisplayName = dn
        } else if let given = givenName, let family = familyName {
            finalDisplayName = "\(given) \(family)"
        } else if let given = givenName {
            finalDisplayName = given
        } else if let family = familyName {
            finalDisplayName = family
        } else {
            finalDisplayName = organization ?? externalId
        }
        
        return PersonPayloadModel(
            external_id: externalId,
            display_name: finalDisplayName,
            given_name: givenName,
            family_name: familyName,
            organization: organization,
            nicknames: nicknames,
            notes: nil,
            photo_hash: photoHash,
            emails: emails,
            phones: phones,
            addresses: [],
            urls: urls
        )
    }
    
    private func extractBase64FromPhoto(_ photoData: String) -> String? {
        // Handle various PHOTO encoding formats
        if photoData.contains("base64,") {
            let components = photoData.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            return components.count > 1 ? String(components[1]) : nil
        } else if photoData.hasPrefix("base64:") {
            return String(photoData.dropFirst(7))
        } else {
            // Assume it's raw base64
            return photoData
        }
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
        // Build payload
        let deviceId = getDeviceId()
        var payload: [String: Any] = [
            "source": "macos_contacts",
            "device_id": deviceId,
            "batch_id": UUID().uuidString,
            "since_token": NSNull(),
            "people": batch.map { person in
                personToDict(person: person)
            }
        ]
        
        // Add self_identifier if configured
        if let selfIdentifier = config.selfIdentifier, !selfIdentifier.isEmpty {
            payload["self_identifier"] = selfIdentifier
        }
        
        // Check if debug mode is enabled
        if config.debug.enabled {
            // Write contact batch payload to debug file
            try await writeContactsBatchToDebugFile(payload: payload)
            logger.debug("Debug mode: wrote contacts batch to debug file", metadata: [
                "count": String(batch.count),
                "output_path": config.debug.outputPath
            ])
            return
        }
        
        // Normal mode: post to gateway
        let url = URL(string: config.gateway.baseUrl + "/catalog/contacts/ingest")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.service.auth.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = TimeInterval(config.gateway.timeoutMs) / 1000.0
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
    
    /// Write contacts batch payload to debug file (JSONL format)
    /// Uses DebugFileWriter to centralize all debug file I/O
    private func writeContactsBatchToDebugFile(payload: [String: Any]) async throws {
        let fileWriter = DebugFileWriter(outputPath: config.debug.outputPath)
        try await fileWriter.writeDictionary(payload)
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
        // Use HavenFilePaths for state directory
        // Ensure directories exist
        try? HavenFilePaths.initializeDirectories()
        
        return HavenFilePaths.stateFile("contacts_collector_state.json")
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

    // MARK: - Error Types
    
    public enum ContactsError: Error, LocalizedError {
        case contactAccessFailed(String)
        case contactAccessDenied(String)
        case vcfLoadFailed(String)
        case invalidGatewayResponse
        case gatewayHttpError(Int, String)
        
        public var errorDescription: String? {
            switch self {
            case .contactAccessFailed(let msg):
                return "Contact access failed: \(msg)"
            case .contactAccessDenied(let msg):
                return "Contact access denied: \(msg)"
            case .vcfLoadFailed(let msg):
                return "VCF load failed: \(msg)"
            case .invalidGatewayResponse:
                return "Invalid response from gateway"
            case .gatewayHttpError(let code, let body):
                return "Gateway HTTP error \(code): \(body)"
            }
        }
    }
}

// MARK: - Contact Payload Types

public struct PersonPayloadModel: Codable, Equatable {
    public let external_id: String
    public let display_name: String
    public let given_name: String?
    public let family_name: String?
    public let organization: String?
    public let nicknames: [String]
    public let notes: String?
    public let photo_hash: String?
    public let emails: [ContactValueModel]
    public let phones: [ContactValueModel]
    public let addresses: [ContactAddressModel]
    public let urls: [ContactUrlModel]
    public let change_token: String?
    public let version: Int
    public let deleted: Bool
    
    enum CodingKeys: String, CodingKey {
        case external_id
        case display_name
        case given_name
        case family_name
        case organization
        case nicknames
        case notes
        case photo_hash
        case emails
        case phones
        case addresses
        case urls
        case change_token
        case version
        case deleted
    }
    
    public init(
        external_id: String,
        display_name: String,
        given_name: String? = nil,
        family_name: String? = nil,
        organization: String? = nil,
        nicknames: [String] = [],
        notes: String? = nil,
        photo_hash: String? = nil,
        emails: [ContactValueModel] = [],
        phones: [ContactValueModel] = [],
        addresses: [ContactAddressModel] = [],
        urls: [ContactUrlModel] = [],
        change_token: String? = nil,
        version: Int = 1,
        deleted: Bool = false
    ) {
        self.external_id = external_id
        self.display_name = display_name
        self.given_name = given_name
        self.family_name = family_name
        self.organization = organization
        self.nicknames = nicknames
        self.notes = notes
        self.photo_hash = photo_hash
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
        self.urls = urls
        self.change_token = change_token
        self.version = version
        self.deleted = deleted
    }
}

public struct ContactValueModel: Codable, Equatable {
    public let value: String
    public let value_raw: String
    public let label: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case value_raw
        case label
    }
    
    public init(value: String, value_raw: String, label: String? = nil) {
        self.value = value
        self.value_raw = value_raw
        self.label = label
    }
}

public struct ContactUrlModel: Codable, Equatable {
    public let label: String?
    public let url: String
    
    enum CodingKeys: String, CodingKey {
        case label
        case url
    }
    
    public init(label: String? = nil, url: String) {
        self.label = label
        self.url = url
    }
}

public struct ContactAddressModel: Codable, Equatable {
    public let label: String?
    public let street: String?
    public let city: String?
    public let region: String?
    public let postal_code: String?
    public let country: String?
    
    enum CodingKeys: String, CodingKey {
        case label
        case street
        case city
        case region
        case postal_code
        case country
    }
    
    public init(
        label: String? = nil,
        street: String? = nil,
        city: String? = nil,
        region: String? = nil,
        postal_code: String? = nil,
        country: String? = nil
    ) {
        self.label = label
        self.street = street
        self.city = city
        self.region = region
        self.postal_code = postal_code
        self.country = country
    }
}
