/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import Markdown
import SymbolKit

/// A set of functions that add automatic symbol curation to a topic graph.
public struct AutomaticCuration {
    /// A value type to store an automatically curated task group and its sorting index.
    struct ReferenceGroup {
        let title: String
        let sortOrder: Int
        var references = [ResolvedTopicReference]()
        
        init(title: String, sortOrder: Int = 0, references: [ResolvedTopicReference] = []) {
            self.title = title
            self.sortOrder = sortOrder
            self.references = references
        }
    }
    
    /// A mapping between a symbol kind and its matching group.
    typealias ReferenceGroupIndex = [SymbolGraph.Symbol.KindIdentifier: ReferenceGroup]
    
    /// A static list of predefined groups for each supported kind of symbol.
    static var groups: ReferenceGroupIndex {
        return groupKindOrder.enumerated().reduce(into: ReferenceGroupIndex()) { (result, next) in
            result[next.element] = ReferenceGroup(title: AutomaticCuration.groupTitle(for: next.element), sortOrder: next.offset)
        }
    }
    
    /// Automatic curation task group.
    typealias TaskGroup = (title: String?, references: [ResolvedTopicReference])
    
    /// Returns a list of automatically curated Topics task groups for the given documentation node.
    /// - Parameters:
    ///   - node: A node for which to generate topics groups.
    ///   - context: A documentation context.
    /// - Returns: An array of title and references list tuples.
    static func topics(
        for node: DocumentationNode,
        withTraits variantsTraits: Set<DocumentationDataVariantsTrait>,
        context: DocumentationContext
    ) throws -> [TaskGroup] {
        let languagesFilter = Set(variantsTraits.compactMap {
            $0.interfaceLanguage.map { SourceLanguage(id: $0) }
        })
        
        let children: [ResolvedTopicReference]
        if languagesFilter.isEmpty {
            // If the caller requests a combined topic section for all source languages, then the results from the `TopicGraph` will be accurate.
            
            // Get any default implementation relationships for this symbol
            //
            // It's okay to include all variants here because we just use this set to filter
            // out these values from automatic curation.
            let defaultImplementationReferences = Set<String>(
                (node.semantic as? Symbol)?.defaultImplementationsVariants.allValues
                    .lazy
                    .map(\.variant)
                    .flatMap(\.implementations)
                    .compactMap { implementation in
                        implementation.reference.url?.absoluteString
                    } ?? []
            )
            
            children = context.children(of: node.reference)
                // Remove any default implementations
                .filter({ reference, _ -> Bool in
                    return !defaultImplementationReferences.contains(reference.absoluteString)
                })
                .map(\.reference)
        } else {
            // If the caller requests topic section for a subset of source languages, then the `TopicGraph` is incapable of producing correct results
            // because it considers all relationships in all languages. Instead we ask the `PathHierarchy` which is source-language-aware.
            children = context.linkResolver.localResolver.directDescendants(of: node.reference, languagesFilter: languagesFilter)
                .sorted(by: \.path)
        }
        
        return try children
            // Force unwrapping as all nodes need to be valid in the rendering phase of the pipeline.
            .reduce(into: AutomaticCuration.groups) { groupsIndex, reference in
                guard let topicNode = context.topicGraph.nodeWithReference(reference),
                      !topicNode.isEmptyExtension,
                      !topicNode.isManuallyCurated
                else {
                    return
                }
                
                // Skip members of "inherited" API collections unless this node is an Inherited API collection.
                guard GeneratedDocumentationTopics.isInheritedSymbolsAPICollectionNode(node.reference, in: context.topicGraph)
                   || !(context.topicGraph.reverseEdges[reference] ?? []).contains(where: { GeneratedDocumentationTopics.isInheritedSymbolsAPICollectionNode($0, in: context.topicGraph) })
                else {
                    return
                }
                
                let childNode = try context.entity(with: reference)
                guard let childSymbol = childNode.semantic as? Symbol else {
                    return
                }
                
                // If we have a specific trait to collect topics for, we only want
                // to include children that have a kind available for that trait.
                //
                // Otherwise, we'll fall back to the first kind variant.
                let childSymbolKindIdentifier: SymbolGraph.Symbol.KindIdentifier?
                if !variantsTraits.isEmpty {
                    if let matchingTrait = variantsTraits.first(where: { childSymbol.kindVariants[$0] != nil }) {
                        childSymbolKindIdentifier = childSymbol.kindVariants[matchingTrait]?.identifier
                    } else {
                        childSymbolKindIdentifier = nil
                    }
                } else {
                    childSymbolKindIdentifier = childSymbol.kindVariants.firstValue?.identifier
                }
                
                if let childSymbolKindIdentifier = childSymbolKindIdentifier {
                    groupsIndex[childSymbolKindIdentifier]?.references.append(reference)
                }
            }
            .lazy
            // Sort the groups in the order intended for rendering
            .sorted(by: \.value.sortOrder)
            // Map to sorted tuples
            .compactMap { groupIndex in
                let group = groupIndex.value
                guard !group.references.isEmpty else { return nil }
                return (title: group.title, references: group.references.sorted(by: \.path))
            }
    }
    
    /// Returns a list of automatically curated See Also task groups for the given documentation node.
    /// - Parameters:
    ///   - node: A node for which to generate a See Also group.
    ///   - context: A documentation context.
    ///   - bundle: A documentation bundle.
    /// - Returns: A group title and the group's references or links.
    ///   `nil` if the method can't find any relevant links to automatically generate a See Also content.
    static func seeAlso(
        for node: DocumentationNode,
        withTraits variantsTraits: Set<DocumentationDataVariantsTrait>,
        context: DocumentationContext,
        bundle: DocumentationBundle,
        renderContext: RenderContext?,
        renderer: DocumentationContentRenderer
    ) -> TaskGroup? {
        if (node.options?.automaticSeeAlsoEnabled ?? context.options?.automaticSeeAlsoEnabled) == false {
            return nil
        }
        
        // First try getting the canonical path from a render context, default to the documentation context
        guard let canonicalPath = renderContext?.store.content(for: node.reference)?.canonicalPath ?? context.pathsTo(node.reference).first,
              let parentReference = canonicalPath.last
        else {
            // If the symbol is not curated or is a root symbol, no See Also please.
            return nil
        }
        
        func filterReferences(_ references: [ResolvedTopicReference]) -> [ResolvedTopicReference] {
            references
                // Don't include the current node.
                .filter { $0 != node.reference }
            
                // Filter out nodes that aren't available in any of the given traits.
                .filter { reference in
                    context.sourceLanguages(for: reference).contains(where: { language in
                        variantsTraits.contains(where: { $0.interfaceLanguage == language.id})
                    })
                }
        }
        
        // Look up the render context first
        if let taskGroups = renderContext?.store.content(for: parentReference)?.taskGroups,
           let linkingGroup = taskGroups.first(where: { $0.references.contains(node.reference) })
        {
            // Group match in render context, verify if there are any other references besides the current one.
            guard linkingGroup.references.count > 1 else { return nil }
            return (title: linkingGroup.title, references: filterReferences(linkingGroup.references))
        }
        
        // Get the parent's task groups
        guard let taskGroups = renderer.taskGroups(for: parentReference) else {
            return nil
        }
        
        // Find the group where the current symbol is curated
        let linkingGroup = taskGroups.first { group -> Bool in
            group.references.contains(node.reference)
        }
        
        // Verify there is a matching linking group and more references than just the current one.
        guard let group = linkingGroup, group.references.count > 1 else {
            return nil
        }
        
        return (title: group.title, references: filterReferences(group.references))
    }
}

extension AutomaticCuration {
    /// Returns a topics group title for the given symbol kind.
    /// - Parameter symbolKind: A symbol kind, such as a protocol or a variable.
    /// - Returns: A group title for symbols of the given kind.
    static func groupTitle(`for` symbolKind: SymbolGraph.Symbol.KindIdentifier) -> String {
        switch symbolKind {
            case .`associatedtype`: return "Associated Types"
            case .`class`: return "Classes"
            case .`deinit`: return "Deinitializers"
            case .`enum`: return "Enumerations"
            case .`case`: return "Enumeration Cases"
            case .dictionary: return "Dictionaries"
            case .extension: return "Extensions"
            case .`func`: return "Functions"
            case .httpRequest: return "Endpoints"
            case .`operator`: return "Operators"
            case .`init`: return "Initializers"
            case .ivar: return "Instance Variables"
            case .macro: return "Macros"
            case .`method`: return "Instance Methods"
            case .namespace: return "Namespaces"
            case .`property`: return "Instance Properties"
            case .`protocol`: return "Protocols"
            case .`struct`: return "Structures"
            case .`subscript`: return "Subscripts"
            case .`typeMethod`: return "Type Methods"
            case .`typeProperty`: return "Type Properties"
            case .`typeSubscript`: return "Type Subscripts"
            case .`typealias`: return "Type Aliases"
            case .union: return "Unions"
            case .`var`: return "Variables"
            case .module: return "Modules"
            case .extendedModule: return "Extended Modules"
            case .extendedClass: return "Extended Classes"
            case .extendedStructure: return "Extended Structures"
            case .extendedEnumeration: return "Extended Enumerations"
            case .extendedProtocol: return "Extended Protocols"
            case .unknownExtendedType: return "Extended Types"
            default: return "Symbols"
        }
    }

    /// The order of symbol kinds when grouped automatically.
    ///
    /// Add a symbol kind to `KindIdentifier.noPageKinds` if it should not generate a page in the
    /// documentation hierarchy.
    static let groupKindOrder: [SymbolGraph.Symbol.KindIdentifier] = [
        .namespace,

        .`class`,
        .`protocol`,
        .`struct`,
        .`union`,
        .`httpRequest`,
        .`dictionary`,
        .`var`,
        .`func`,
        .`operator`,
        .`macro`,

        .`associatedtype`,
        .`case`,
        .`init`,
        .`deinit`,
        .`ivar`,
        .`property`,
        .`method`,
        .`subscript`,

        .`typealias`,
        .`typeProperty`,
        .`typeMethod`,
        .`enum`,
        .`typeSubscript`,
        
        .extendedModule,
        .extendedClass,
        .extendedProtocol,
        .extendedStructure,
        .extendedEnumeration,
        .unknownExtendedType,

        .extension,
    ]
}
