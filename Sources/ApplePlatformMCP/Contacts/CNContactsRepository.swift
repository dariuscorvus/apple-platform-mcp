import Contacts
import Foundation

/// All synchronous framework access stays actor-isolated; only value models leave it.
public actor CNContactsRepository: ContactsRepository {
  private let store = CNContactStore()
  public init() {}
  public nonisolated static func currentAuthorizationStatus() -> ContactsAccess {
    ContactsAccess.normalized(CNContactStore.authorizationStatus(for: .contacts).rawValue)
  }
  public func authorizationStatus() -> ContactsAccess { Self.currentAuthorizationStatus() }
  public func requestAccess() async throws -> ContactsAccess {
    do { _ = try await store.requestAccess(for: .contacts) } catch {
      throw ContactsError("contactsPermissionDenied")
    }
    return authorizationStatus()
  }
  private func requireRead() throws -> ContactsAccess {
    let a = authorizationStatus()
    guard a.readable else {
      throw ContactsError(
        a == .notDetermined ? "contactsPermissionRequired" : "contactsPermissionDenied")
    }
    return a
  }
  private let visibility = "authorized_visible_subset_no_account_completeness_claim"
  private func containers() throws -> [CNContainer] {
    _ = try requireRead()
    do { return try store.containers(matching: nil).sorted { $0.identifier < $1.identifier } } catch
    { throw ContactsError("contactsUnavailable") }
  }
  public func listContainers(maximum: Int) throws -> ContactsPage<ContactsContainer> {
    let a = try requireRead()
    let cs = try containers()
    let values = try cs.prefix(maximum).map { c in
      ContactsContainer(
        id: try ContactsReferenceCodec.encode(container: c.identifier),
        name: String(c.name.prefix(256)),
        provider_type: c.type == .local
          ? "local" : c.type == .exchange ? "exchange" : c.type == .cardDAV ? "carddav" : "unknown")
    }
    return .init(
      items: values, authorization: a, visibility: visibility,
      truncated: cs.count > maximum || values.contains { $0.name.count == 256 },
      scan_complete: cs.count <= maximum,
      records_examined: values.count, limit: maximum)
  }
  private func keys(_ fields: [ContactsField], detail: Bool = false) -> [CNKeyDescriptor] {
    var k = [
      CNContactIdentifierKey, CNContactTypeKey, CNContactGivenNameKey, CNContactFamilyNameKey,
      CNContactOrganizationNameKey,
    ]
    if fields.contains(.name) || detail {
      k += [CNContactMiddleNameKey, CNContactNamePrefixKey, CNContactNameSuffixKey]
    }
    if fields.contains(.email) || detail { k.append(CNContactEmailAddressesKey) }
    if fields.contains(.phone) || detail { k.append(CNContactPhoneNumbersKey) }
    return k.map { $0 as CNKeyDescriptor }
  }
  private func summary(_ c: CNContact, container: String) throws -> ContactsSummary {
    let text = [c.givenName, c.familyName, c.organizationName]
    return .init(
      id: try ContactsReferenceCodec.encode(container: container, record: c.identifier),
      container_id: try ContactsReferenceCodec.encode(container: container),
      kind: c.contactType == .organization ? "organization" : "person",
      given_name: String(c.givenName.prefix(256)), family_name: String(c.familyName.prefix(256)),
      organization: String(c.organizationName.prefix(256)),
      truncated: text.contains { $0.count > 256 })
  }
  public func search(_ query: ContactsQuery, maximumScan: Int) throws -> ContactsPage<
    ContactsSummary
  > {
    let access = try requireRead()
    let all = try containers()
    let selected: [CNContainer]
    if let ids = query.containerIDs {
      let raw = try ids.map { try ContactsReferenceCodec.decode($0, record: false).container }
      guard raw.allSatisfy({ id in all.contains { $0.identifier == id } }) else {
        throw ContactsError("contactsNotFound")
      }
      selected = all.filter { raw.contains($0.identifier) }
    } else {
      selected = all
    }
    var result: [ContactsSummary] = []
    var examined = 0
    var complete = true
    do {
      for container in selected {
        let req = CNContactFetchRequest(keysToFetch: keys(query.fields))
        req.unifyResults = false
        req.mutableObjects = false
        req.sortOrder = .familyName
        req.predicate = CNContact.predicateForContactsInContainer(
          withIdentifier: container.identifier)
        var mappingError: Error?
        try store.enumerateContacts(with: req) { c, stop in
          if examined >= maximumScan {
            complete = false
            stop.pointee = true
            return
          }
          examined += 1
          let names =
            query.fields.contains(.name)
            ? [c.namePrefix, c.givenName, c.middleName, c.familyName, c.nameSuffix] : []
          let emails =
            query.fields.contains(.email) ? c.emailAddresses.map { $0.value as String } : []
          let phones =
            query.fields.contains(.phone) ? c.phoneNumbers.map { $0.value.stringValue } : []
          if query.matches(
            names: names, company: c.organizationName, emails: emails, phones: phones)
          {
            if result.count >= query.limit {
              complete = false
              stop.pointee = true
              return
            }
            do { result.append(try self.summary(c, container: container.identifier)) } catch {
              mappingError = error
              stop.pointee = true
            }
          }
        }
        if let mappingError { throw mappingError }
        if !complete { break }
      }
    } catch let e as ContactsError { throw e } catch { throw ContactsError("contactsUnavailable") }
    result.sort {
      (ContactsQuery.fold($0.family_name), ContactsQuery.fold($0.given_name), $0.id) < (
        ContactsQuery.fold($1.family_name), ContactsQuery.fold($1.given_name), $1.id
      )
    }
    let after = try requireRead()
    return .init(
      items: result, authorization: after, visibility: visibility,
      truncated: !complete || result.contains { $0.truncated } || access != after,
      scan_complete: complete && access == after, records_examined: examined, limit: query.limit)
  }
  public func get(id: String) throws -> ContactsRecord {
    _ = try requireRead()
    let a = try ContactsReferenceCodec.decode(id, record: true)
    guard try containers().contains(where: { $0.identifier == a.container }) else {
      throw ContactsError("contactsNotFound")
    }
    let req = CNContactFetchRequest(keysToFetch: keys([], detail: true))
    req.unifyResults = false
    req.mutableObjects = false
    req.predicate = CNContact.predicateForContacts(withIdentifiers: [a.record!])
    var found: [CNContact] = []
    do {
      try store.enumerateContacts(with: req) { c, stop in
        if c.identifier == a.record { found.append(c) }
        if found.count > 1 { stop.pointee = true }
      }
    } catch { throw ContactsError("contactsNotFound") }
    guard found.count <= 1 else { throw ContactsError("contactsAmbiguousReference") }
    guard let c = found.first else { throw ContactsError("contactsNotFound") }
    // Container membership is checked independently with the exact record ID.
    let membership = try store.containers(
      matching: CNContainer.predicateForContainerOfContact(withIdentifier: c.identifier))
    guard membership.contains(where: { $0.identifier == a.container }) else {
      throw ContactsError("contactsNotFound")
    }
    let summary = try summary(c, container: a.container)
    func clip(_ s: String) -> String { String(s.prefix(512)) }
    func label(_ s: String?) -> String {
      s.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "unlabeled"
    }
    let emailValues = c.emailAddresses.prefix(100).map {
      ContactsChannel(label: label($0.label), value: $0.value as String)
    }
    let phoneValues = c.phoneNumbers.prefix(100).map {
      ContactsChannel(label: label($0.label), value: $0.value.stringValue)
    }
    let values = emailValues + phoneValues
    let clipped =
      summary.truncated || c.emailAddresses.count > 100 || c.phoneNumbers.count > 100
      || values.contains { $0.label.count > 512 || $0.value.count > 512 }
      || [c.middleName, c.namePrefix, c.nameSuffix].contains { $0.count > 512 }
    let emails = emailValues.map { ContactsChannel(label: clip($0.label), value: clip($0.value)) }
    let phones = phoneValues.map { ContactsChannel(label: clip($0.label), value: clip($0.value)) }
    let middle = clip(c.middleName)
    let prefix = clip(c.namePrefix)
    let suffix = clip(c.nameSuffix)
    _ = try requireRead()
    return .init(
      summary: summary, middle_name: middle, name_prefix: prefix, name_suffix: suffix,
      emails: emails, phones: phones, truncated: clipped)
  }
}
