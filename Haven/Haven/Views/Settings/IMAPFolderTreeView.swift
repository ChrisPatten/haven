//
//  IMAPFolderTreeView.swift
//  Haven
//
//  Hierarchical folder tree view with checkboxes for IMAP folder selection
//

import SwiftUI

/// Represents a folder node in the hierarchical tree
struct FolderNode: Identifiable {
    let id: String
    let name: String
    let fullPath: String
    var children: [FolderNode]
    var isSelected: Bool
    
    init(path: String, delimiter: String, children: [FolderNode] = [], isSelected: Bool = false) {
        self.id = path
        self.fullPath = path
        self.name = path.components(separatedBy: delimiter).last ?? path
        self.children = children
        self.isSelected = isSelected
    }
}

/// Builds a hierarchical tree from flat folder list
struct FolderTreeBuilder {
    static func buildTree(from folders: [ImapFolder], delimiter: String = "/") -> [FolderNode] {
        guard !folders.isEmpty else { return [] }
        
        // Use delimiter from first folder, or default to "/"
        let defaultDelimiter = folders.first?.delimiter.isEmpty == false ? folders.first!.delimiter : "/"
        let effectiveDelimiter = delimiter.isEmpty ? defaultDelimiter : delimiter
        
        // Sort folders by path depth first, then alphabetically
        let sortedFolders = folders.sorted { folder1, folder2 in
            let components1 = folder1.path.components(separatedBy: effectiveDelimiter).filter { !$0.isEmpty }
            let components2 = folder2.path.components(separatedBy: effectiveDelimiter).filter { !$0.isEmpty }
            if components1.count != components2.count {
                return components1.count < components2.count
            }
            return folder1.path < folder2.path
        }
        
        // Build a dictionary of nodes by path
        var nodeMap: [String: FolderNode] = [:]
        
        // First pass: create all nodes
        for folder in sortedFolders {
            let node = FolderNode(path: folder.path, delimiter: effectiveDelimiter)
            nodeMap[folder.path] = node
        }
        
        // Second pass: build hierarchy (process deeper folders first)
        var rootNodes: Set<String> = []
        
        for folder in sortedFolders {
            let path = folder.path
            let components = path.components(separatedBy: effectiveDelimiter).filter { !$0.isEmpty }
            
            if components.count == 1 {
                // Root level folder
                rootNodes.insert(path)
            } else {
                // Find parent path
                let parentComponents = components.dropLast()
                let parentPath = parentComponents.joined(separator: effectiveDelimiter)
                
                // Get or create parent node
                var parentNode: FolderNode
                if let existingParent = nodeMap[parentPath] {
                    parentNode = existingParent
                } else {
                    // Create virtual parent
                    parentNode = FolderNode(path: parentPath, delimiter: effectiveDelimiter)
                    nodeMap[parentPath] = parentNode
                    // Mark as root if it's a top-level parent
                    if parentComponents.count == 1 {
                        rootNodes.insert(parentPath)
                    }
                }
                
                // Add child to parent
                if let childNode = nodeMap[path] {
                    parentNode.children.append(childNode)
                    nodeMap[parentPath] = parentNode
                }
            }
        }
        
        // Build result from root nodes
        var result: [FolderNode] = []
        for rootPath in rootNodes.sorted() {
            if let rootNode = nodeMap[rootPath] {
                result.append(rootNode)
            }
        }
        
        // Sort children recursively
        func sortChildren(_ node: inout FolderNode) {
            node.children.sort { $0.name < $1.name }
            for i in node.children.indices {
                sortChildren(&node.children[i])
            }
        }
        
        for i in result.indices {
            sortChildren(&result[i])
        }
        
        return result
    }
    
    /// Collects all selected folder paths from the tree
    static func collectSelectedPaths(from nodes: [FolderNode]) -> [String] {
        var selected: [String] = []
        
        func traverse(_ node: FolderNode) {
            if node.isSelected {
                selected.append(node.fullPath)
            }
            for child in node.children {
                traverse(child)
            }
        }
        
        for node in nodes {
            traverse(node)
        }
        
        return selected
    }
    
    /// Updates selection state for a node and its children
    static func updateSelection(_ nodeId: String, isSelected: Bool, in nodes: inout [FolderNode]) {
        func updateNode(_ node: inout FolderNode) {
            if node.id == nodeId {
                node.isSelected = isSelected
                // Update all children
                for i in node.children.indices {
                    node.children[i].isSelected = isSelected
                }
            } else {
                // Recursively update children
                for i in node.children.indices {
                    updateNode(&node.children[i])
                }
            }
        }
        
        for i in nodes.indices {
            updateNode(&nodes[i])
        }
    }
}

/// IMAP folder data structure matching backend response
struct ImapFolder: Codable, Identifiable {
    let id: String
    let path: String
    let delimiter: String
    let flags: [String]
    
    enum CodingKeys: String, CodingKey {
        case path
        case delimiter
        case flags
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        delimiter = try container.decode(String.self, forKey: .delimiter)
        flags = try container.decode([String].self, forKey: .flags)
        id = path
    }
    
    init(path: String, delimiter: String, flags: [String]) {
        self.path = path
        self.delimiter = delimiter
        self.flags = flags
        self.id = path
    }
}

/// Hierarchical folder tree view with checkboxes
struct IMAPFolderTreeView: View {
    @Binding var selectedFolders: [String]
    let folders: [ImapFolder]
    
    @State private var treeNodes: [FolderNode] = []
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if treeNodes.isEmpty {
                    Text("No folders available")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .padding()
                } else {
                    ForEach(treeNodes) { node in
                        FolderNodeView(
                            node: node,
                            onSelectionChanged: { nodeId, isSelected in
                                updateSelection(nodeId: nodeId, isSelected: isSelected)
                            }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 300)
        .onAppear {
            buildTree()
        }
        .onChange(of: folders.count) { _, _ in
            buildTree()
        }
        .onChange(of: selectedFolders) { _, _ in
            restoreSelection()
        }
    }
    
    private func buildTree() {
        // Determine delimiter (use most common delimiter from folders)
        let delimiter = folders.first?.delimiter ?? "/"
        
        treeNodes = FolderTreeBuilder.buildTree(from: folders, delimiter: delimiter)
        
        // Restore selection state
        restoreSelection()
    }
    
    private func updateSelection(nodeId: String, isSelected: Bool) {
        FolderTreeBuilder.updateSelection(nodeId, isSelected: isSelected, in: &treeNodes)
        selectedFolders = FolderTreeBuilder.collectSelectedPaths(from: treeNodes)
    }
    
    private func restoreSelection() {
        // Update tree nodes based on selectedFolders
        func updateNode(_ node: inout FolderNode) {
            node.isSelected = selectedFolders.contains(node.fullPath)
            for i in node.children.indices {
                updateNode(&node.children[i])
            }
        }
        
        for i in treeNodes.indices {
            updateNode(&treeNodes[i])
        }
    }
}

/// View for a single folder node with recursive children
struct FolderNodeView: View {
    let node: FolderNode
    let onSelectionChanged: (String, Bool) -> Void
    
    @State private var isExpanded: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // Expand/collapse button for folders with children
                if !node.children.isEmpty {
                    Button(action: {
                        isExpanded.toggle()
                    }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 12)
                }
                
                // Checkbox
                Button(action: {
                    onSelectionChanged(node.id, !node.isSelected)
                }) {
                    Image(systemName: node.isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(node.isSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                
                // Folder name
                Text(node.name)
                    .font(.caption)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            
            // Children
            if isExpanded && !node.children.isEmpty {
                ForEach(node.children) { child in
                    FolderNodeView(
                        node: child,
                        onSelectionChanged: onSelectionChanged
                    )
                    .padding(.leading, 20)
                }
            }
        }
    }
}

