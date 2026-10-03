#!/usr/bin/env ruby
# frozen_string_literal: true

# Wiring regression tripwires complement executable scope/Core tests. These
# cannot qualify a native OS runtime or replace installed-app journeys.
observer = File.read('Barline/MenuBar/MenuBarItems/GoldenGatePlatformPresenceObserver.swift')
provider = File.read('Barline/MenuBar/MenuBarItems/GoldenGateAXSnapshotProvider.swift')
helper = File.read('BarlineMenuService/Backends/GoldenGateConcealmentController.swift')
scope = File.read('Shared/Utilities/AXNativeScopeValidationSupport.swift')

unless observer.include?('AXNativeScopeValidationSupport.canAttemptObservation(on: ProcessInfo.processInfo.operatingSystemVersion)') &&
       observer.include?('guard Self.requiresQualifiedPresenceContract else')
  abort('native observation must use the tested minimum-OS attempt predicate')
end
if [observer, scope].any? { |source| source.match?(/sysctl|kern\.osversion|minorVersion|patchVersion|26A434/) }
  abort('patch or kernel-build metadata must not deny a structural observation attempt')
end
unless provider.include?('guard !requiresQualifiedPresenceContract || nativePresenceCapture != nil else') &&
       provider.include?('guard !requiresQualifiedPresenceContract || platformPresenceObservation != nil else') &&
       provider.include?('guard !requiresQualifiedPresenceContract || envelope.scan?.platformPresenceObservation != nil else')
  abort('unknown capture, Focus projection or envelope association must still fail closed')
end

collection = provider.split('private func collectAuthorityObservation(', 2).last
  .split('private func captureNativePlatformPresence(', 2).first
association = collection.index('guard !requiresQualifiedPresenceContract || envelope.scan?.platformPresenceObservation != nil else')
%w[commitIdentityMigration( rememberSections( commitRetainedInventory(].each do |write|
  position = collection.index(write)
  abort("inventory persistence precedes complete observation association: #{write}") unless
    association && position && position > association
end
%w[explicitAssignments rememberedSections retainedDescriptors].each do |state|
  abort("unqualified observation directly writes #{state}") if
    collection[0...association].match?(/^\s*(?:self\.)?#{state}\s*=/)
end
unless collection.index('cachedAt = DispatchTime.now().uptimeNanoseconds').to_i > association &&
       collection.index('cachedSnapshot = result').to_i > association
  abort('only associated, persisted observations may enter the publication cache')
end

unless helper.include?('forInfoKey: "BarlineAppSigningIdentifier"') &&
       helper.scan('barlineBundleIdentifier: barlineBundleIdentifier').length == 2 &&
       !helper.include?('"com.mabryventures.Barline"')
  abort('native resolution and allowlist must share the authenticated configured app identity')
end

puts 'PASS: runtime presence admission, association-before-persistence and configured helper identity wiring'
