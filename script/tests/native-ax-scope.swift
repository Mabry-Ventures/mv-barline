import ApplicationServices
import Foundation

@main
enum NativeScopeTests {
    static let pid: Int32 = 123
    static let bounds = CGRect(x: 100, y: 0, width: 22, height: 22)
    static func node(_ token: UInt32, identifier: AXStringRead = .noValue, role: String,
                     subrole: AXStringRead = .noValue, children: AXNativeScopeMembership = .elements([]),
                     geometry: AXGeometryRead? = nil, owner: AXProcessIdentifierRead = .value(pid)) -> AXNativeScopeNode
    {
        let read = AXNativeScopeNodeRead(identity: .attributes(AXIdentityAttributes(identifier: identifier, role: .value(role), subrole: subrole)),
                                         owner: owner, geometry: geometry, children: children)
        return AXNativeScopeNode(token: token, before: read, after: read)
    }

    static func leaf(_ token: UInt32, _ identifier: String) -> AXNativeScopeNode {
        node(token, identifier: .value(identifier), role: "AXMenuBarItem", subrole: .value("AXMenuExtra"), geometry: .bounds(bounds))
    }

    static func forest(focus: Bool = false) -> [AXNativeScopeNode] {
        var nodes = [node(1, role: "AXMenuBar", children: .elements(focus ? [2, 3, 6] : [2, 3])),
                     node(2, role: "AXGroup", subrole: .value("AXHostingView"), children: .elements([4])),
                     node(3, role: "AXGroup", subrole: .value("AXHostingView"), children: .elements([5])),
                     leaf(4, AXNativeScopeValidationSupport.clockIdentifier), leaf(5, AXNativeScopeValidationSupport.controlCenterIdentifier)]
        if focus {
            nodes += [node(6, role: "AXGroup", subrole: .value("AXHostingView"), children: .elements([7])),
                      leaf(7, AXNativeScopeValidationSupport.focusIdentifier)]
        }
        return nodes
    }

    static func changed(_ node: AXNativeScopeNode, identifier: AXStringRead? = nil, role: AXStringRead? = nil,
                        owner: AXProcessIdentifierRead? = nil, children: AXNativeScopeMembership? = nil,
                        geometry: AXGeometryRead? = nil, afterOnly: Bool = false) -> AXNativeScopeNode
    {
        guard case let .attributes(identity) = node.before.identity else { fatalError("fixture_identity") }
        let read = AXNativeScopeNodeRead(identity: .attributes(AXIdentityAttributes(identifier: identifier ?? identity.identifier,
                                                                                    role: role ?? identity.role, subrole: identity.subrole)),
                                         owner: owner ?? node.before.owner, geometry: geometry ?? node.before.geometry,
                                         children: children ?? node.before.children)
        return AXNativeScopeNode(token: node.token, before: afterOnly ? node.before : read, after: read)
    }

    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ code: String) {
            guard value else { print("FAIL: \(code)"); exit(1) }
            checks += 1
        }
        func closed(_ nodes: [AXNativeScopeNode]) -> AXNativeClosedScope? {
            if case let .closed(scope) = AXNativeScopeValidationSupport.validate(extrasToken: 1, nodes: nodes, ownerPID: pid) {
                return scope
            }
            return nil
        }
        func unknown(_ nodes: [AXNativeScopeNode], _ reason: AXNativeScopeFailure) -> Bool {
            AXNativeScopeValidationSupport.validate(extrasToken: 1, nodes: nodes, ownerPID: pid) == .unknown(reason)
        }
        for (major, minor, patch) in [(26, 0, 0), (26, 9, 9), (27, 0, 0), (27, 0, 1), (27, 0, 2), (27, 1, 0), (28, 0, 0)] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
            let admitted = AXNativeScopeValidationSupport.canAttemptObservation(on: version)
            expect(admitted == (major >= 27), "observation_attempt_eligibility_\(major)_\(minor)_\(patch)")
            if admitted {
                // Eligibility is not qualification, including on future OS releases.
                expect(closed(forest()) != nil, "eligible_closed_scope_\(major)_\(minor)_\(patch)")
                expect(unknown([], .nodeLimit), "eligible_unknown_still_rejected_\(major)_\(minor)_\(patch)")
            }
        }
        let baseline = forest()
        expect(closed(baseline)?.leafTokens == [4, 5] && closed(baseline)?.focusToken == nil, "closed_no_focus_scope_not_mode_state")
        expect(closed(forest(focus: true))?.focusToken == 7, "exact_focus_leaf_in_closed_scope")
        expect(!((baseline[0] as Any) is any Encodable), "node_facts_not_codable")
        expect(unknown([], .nodeLimit), "empty_scope_not_absence")
        expect(unknown(baseline + [baseline[0]], .duplicateNode), "duplicate_record")
        expect(unknown(Array(baseline.dropFirst()), .orphanNode), "missing_extras_record")
        expect(unknown(baseline + [leaf(9, "other")], .orphanNode), "unreferenced_record")
        for identity in [AXStringRead.unsupported, .failure(AXReadFailure(.cannotComplete)), .value("")] {
            var nodes = baseline; nodes[1] = changed(nodes[1], identifier: identity)
            expect(unknown(nodes, .unexpectedShape), "wrapper_no_value_is_not_unsupported_or_empty")
        }
        for membership in [AXNativeScopeMembership.noValue, .unsupported, .failure(AXReadFailure(.cannotComplete)), .elements([9])] {
            var nodes = baseline; nodes[3] = changed(nodes[3], children: membership)
            expect(unknown(nodes, .openFrontier), "leaf_unknown_or_nonempty_is_not_closed")
        }
        for membership in [AXNativeScopeMembership.elements([3, 2]), .elements([2, 9]), .unsupported] {
            var nodes = baseline; nodes[0] = changed(nodes[0], children: membership, afterOnly: true)
            expect(unknown(nodes, .changedNode), "same_count_reorder_or_replacement_rejected")
        }
        var nodes = baseline; nodes[2] = changed(nodes[2], children: .elements([4]))
        expect(unknown(nodes, .duplicateNode), "cross_parent_alias_rejected")
        nodes = baseline; nodes[3] = changed(nodes[3], owner: .value(456))
        expect(unknown(nodes, .readUnknown), "same_node_owner_required")
        nodes = baseline; nodes[3] = changed(nodes[3], owner: .value(456), afterOnly: true)
        expect(unknown(nodes, .changedNode), "owner_replacement_rejected")
        nodes = baseline; nodes[3] = changed(nodes[3], geometry: .bounds(CGRect(x: 101, y: 0, width: 22, height: 22)), afterOnly: true)
        expect(unknown(nodes, .changedNode), "same_node_geometry_drift_rejected")
        for value in [AXGeometryRead.noValue, .unsupported, .failure(AXReadFailure(.cannotComplete)),
                      .bounds(CGRect(x: 0, y: 0, width: 0, height: 22))]
        {
            nodes = baseline; nodes[3] = changed(nodes[3], geometry: value)
            expect(unknown(nodes, .unusableGeometry), "no_wrapper_geometry_fallback")
        }
        for value in [AXStringRead.noValue, .unsupported, .failure(AXReadFailure(.wrongType)), .value("")] {
            nodes = baseline; nodes[3] = changed(nodes[3], identifier: value)
            expect(unknown(nodes, .invalidIdentity), "unreadable_terminal_sibling_not_dropped")
        }
        nodes = forest(focus: true); nodes[0] = changed(nodes[0], children: .elements([2, 3, 6, 8]))
        nodes += [node(8, role: "AXGroup", subrole: .value("AXHostingView"), children: .elements([9])),
                  leaf(9, " COM.APPLE.MENUEXTRA.FOCUSMODE ")]
        expect(unknown(nodes, .duplicateNode), "normalized_domain_collision_is_not_new_focus_alias")
        nodes = forest(focus: true); nodes[6] = changed(nodes[6], identifier: .value(" COM.APPLE.MENUEXTRA.FOCUSMODE "))
        expect(closed(nodes)?.focusToken == nil, "variant_never_catalogue_authorized")
        nodes = baseline; nodes[3] = changed(nodes[3], identifier: .value("other.readable.closed.item"))
        expect(unknown(nodes, .missingAnchor), "clock_anchor_cannot_be_replaced_by_arbitrary_leaf")
        nodes = baseline; nodes[0] = changed(nodes[0], children: .elements([2, 3, 6]))
        nodes += [node(6, role: "AXGroup", subrole: .value("AXHostingView"), children: .elements([7])), leaf(7, "other.readable.closed.item")]
        expect(closed(nodes)?.leafTokens == [4, 5, 7], "closed_generic_sibling_needs_no_product_label_catalogue")

        func largeForest(_ count: Int) -> [AXNativeScopeNode] {
            var nodes = [node(1, role: "AXMenuBar", children: .elements([2, 3, 4]))]
            let leaves = Array(5 ... UInt32(count))
            for (index, token) in [UInt32(2), 3, 4].enumerated() {
                let start = index * 63; let end = min(start + 63, leaves.count)
                nodes.append(node(token, role: "AXGroup", subrole: .value("AXHostingView"), children: .elements(Array(leaves[start ..< end]))))
            }
            for token in leaves {
                let identifier = token == 5 ? AXNativeScopeValidationSupport.clockIdentifier : token == 6 ?
                    AXNativeScopeValidationSupport.controlCenterIdentifier : "closed.other.\(token)"
                nodes.append(leaf(token, identifier))
            }
            return nodes
        }
        expect(closed(largeForest(192)) != nil, "192_node_closed_boundary")
        expect(unknown(largeForest(193), .nodeLimit), "193_node_boundary_unknown")
        print("PASS: \(checks) pure closed AX scope, membership, same-node and ambiguity checks; no native reads or absence authority")
    }
}
