//
//  TreeMap.swift
//  SideStore
//
//  Created by Magesh K on 21/02/25.
//  Copyright © 2025 SideStore. All rights reserved.
//

public class TreeMap<Key: Comparable, Value>: Sequence {
    
    // MARK: - Node and Color Definitions
    
    fileprivate enum Color {
        case red
        case black
    }
    
    fileprivate class Node {
        var key: Key
        var value: Value
        var left: Node?
        var right: Node?
        weak var parent: Node?
        var color: Color
        
        init(key: Key, value: Value, color: Color = .red, parent: Node? = nil) {
            self.key = key
            self.value = value
            self.color = color
            self.parent = parent
        }
    }
    
    // MARK: - TreeMap Properties and Initializer
    
    private var root: Node?
    public private(set) var count: Int = 0
    
    public init() {}
    
    // MARK: - Public Dictionary-like API
    
    /// Subscript: Get or set value for a given key.
    public subscript(key: Key) -> Value? {
        get { return get(key: key) }
        set {
            if let newValue = newValue {
                _ = insert(key: key, value: newValue)
            } else {
                _ = remove(key: key)
            }
        }
    }
    
    /// Returns the value associated with the given key.
    public func get(key: Key) -> Value? {
        guard let node = getNode(forKey: key) else { return nil }
        return node.value
    }
    
    /// Inserts (or updates) the key with the given value.
    /// Returns the old value if the key was already present.
    @discardableResult
    public func insert(key: Key, value: Value) -> Value? {
        if let node = getNode(forKey: key) {
            let oldValue = node.value
            node.value = value
            return oldValue
        }
        // Create new node
        let newNode = Node(key: key, value: value)
        var parent: Node? = nil
        var current = root
        while let cur = current {
            parent = cur
            if newNode.key < cur.key {
                current = cur.left
            } else {
                current = cur.right
            }
        }
        newNode.parent = parent
        if parent == nil {
            root = newNode
        } else if newNode.key < parent!.key {
            parent!.left = newNode
        } else {
            parent!.right = newNode
        }
        count += 1
        fixAfterInsertion(newNode)
        return nil
    }
    
    /// Removes the node with the given key.
    /// Returns the removed value if it existed.
    @discardableResult
    public func remove(key: Key) -> Value? {
        guard let node = getNode(forKey: key) else { return nil }
        let removedValue = node.value
        deleteNode(node)
        count -= 1
        return removedValue
    }
    
    /// Returns true if the map is empty.
    public var isEmpty: Bool {
        return count == 0
    }
    
    /// Returns all keys in sorted order.
    public var keys: [Key] {
        var result = [Key]()
        for (key, _) in self { result.append(key) }
        return result
    }
    
    /// Returns all values in order of their keys.
    public var values: [Value] {
        var result = [Value]()
        for (_, value) in self { result.append(value) }
        return result
    }
    
    /// Removes all entries.
    public func removeAll() {
        root = nil
        count = 0
    }
    
    // MARK: - Internal Helper Methods
    
    /// Standard BST search for a node matching the key.
    private func getNode(forKey key: Key) -> Node? {
        var current = root
        while let node = current {
            if key == node.key {
                return node
            } else if key < node.key {
                current = node.left
            } else {
                current = node.right
            }
        }
        return nil
    }
    
    /// Returns the minimum node in the subtree rooted at `node`.
    private func minimum(_ node: Node) -> Node {
        var current = node
        while let next = current.left {
            current = next
        }
        return current
    }
    
    // MARK: - Rotation Methods
    
    private func rotateLeft(_ node: Node) {
        guard let child = node.right else { return }
        node.right = child.left
        if let leftChild = child.left {
            leftChild.parent = node
        }
        child.parent = node.parent
        if node.parent == nil {
            root = child
        } else if node === node.parent?.left {
            node.parent?.left = child
        } else {
            node.parent?.right = child
        }
        child.left = node
        node.parent = child
    }
    
    private func rotateRight(_ node: Node) {
        guard let child = node.left else { return }
        node.left = child.right
        if let rightChild = child.right {
            rightChild.parent = node
        }
        child.parent = node.parent
        if node.parent == nil {
            root = child
        } else if node === node.parent?.right {
            node.parent?.right = child
        } else {
            node.parent?.left = child
        }
        child.right = node
        node.parent = child
    }
    
    // MARK: - Insertion Fix-Up
    
    /// Restores red–black properties after insertion.
    private func fixAfterInsertion(_ inserted: Node) {
        var node = inserted
        node.color = .red
        while node !== root, let parent = node.parent, parent.color == .red {
            if parent === parent.parent?.left {
                if let uncle = parent.parent?.right, uncle.color == .red {
                    parent.color = .black
                    uncle.color = .black
                    parent.parent?.color = .red
                    if let grandparent = parent.parent {
                        node = grandparent
                    }
                } else {
                    if node === parent.right {
                        node = parent
                        rotateLeft(node)
                    }
                    node.parent?.color = .black
                    node.parent?.parent?.color = .red
                    if let grandparent = node.parent?.parent {
                        rotateRight(grandparent)
                    }
                }
            } else {
                if let uncle = parent.parent?.left, uncle.color == .red {
                    parent.color = .black
                    uncle.color = .black
                    parent.parent?.color = .red
                    if let grandparent = parent.parent {
                        node = grandparent
                    }
                } else {
                    if node === parent.left {
                        node = parent
                        rotateRight(node)
                    }
                    node.parent?.color = .black
                    node.parent?.parent?.color = .red
                    if let grandparent = node.parent?.parent {
                        rotateLeft(grandparent)
                    }
                }
            }
        }
        root?.color = .black
    }
    
    // MARK: - Deletion Helpers
    
    /// Replaces subtree rooted at u with subtree rooted at v.
    private func transplant(_ outgoing: Node, _ incoming: Node?) {
        if outgoing.parent == nil {
            root = incoming
        } else if outgoing === outgoing.parent?.left {
            outgoing.parent?.left = incoming
        } else {
            outgoing.parent?.right = incoming
        }
        if let incomingNode = incoming {
            incomingNode.parent = outgoing.parent
        }
    }
    
    /// Deletes node z and fixes red–black properties.
    private func deleteNode(_ target: Node) {
        var replacement = target
        let originalColor = replacement.color
        var movedChild: Node?
        
        if target.left == nil {
            movedChild = target.right
            transplant(target, target.right)
        } else if target.right == nil {
            movedChild = target.left
            transplant(target, target.left)
        } else {
            replacement = minimum(target.right!)
            let replacementOriginalColor = replacement.color
            movedChild = replacement.right
            if replacement.parent === target {
                if movedChild != nil { movedChild!.parent = replacement }
            } else {
                transplant(replacement, replacement.right)
                replacement.right = target.right
                replacement.right?.parent = replacement
            }
            transplant(target, replacement)
            replacement.left = target.left
            replacement.left?.parent = replacement
            replacement.color = target.color
            if replacementOriginalColor == .black {
                fixAfterDeletion(movedChild, parent: replacement.parent)
            }
            return
        }
        if originalColor == .black {
            fixAfterDeletion(movedChild, parent: target.parent)
        }
    }
    
    /// Restores red–black properties after deletion.
    private func fixAfterDeletion(_ node: Node?, parent: Node?) {
        var node = node
        var parent = parent
        while (node == nil || node!.color == .black) && (node !== root) {
            if node === parent?.left {
                var sibling = parent?.right
                if sibling?.color == .red {
                    sibling?.color = .black
                    parent?.color = .red
                    rotateLeft(parent!)
                    sibling = parent?.right
                }
                if (sibling?.left == nil || sibling?.left?.color == .black) &&
                   (sibling?.right == nil || sibling?.right?.color == .black) {
                    sibling?.color = .red
                    node = parent
                    parent = node?.parent
                } else {
                    if sibling?.right == nil || sibling?.right?.color == .black {
                        sibling?.left?.color = .black
                        sibling?.color = .red
                        if let wUnwrapped = sibling { rotateRight(wUnwrapped) }
                        sibling = parent?.right
                    }
                    sibling?.color = parent?.color ?? .black
                    parent?.color = .black
                    sibling?.right?.color = .black
                    rotateLeft(parent!)
                    node = root
                    parent = nil
                }
            } else {
                var sibling = parent?.left
                if sibling?.color == .red {
                    sibling?.color = .black
                    parent?.color = .red
                    rotateRight(parent!)
                    sibling = parent?.left
                }
                if (sibling?.left == nil || sibling?.left?.color == .black) &&
                   (sibling?.right == nil || sibling?.right?.color == .black) {
                    sibling?.color = .red
                    node = parent
                    parent = node?.parent
                } else {
                    if sibling?.left == nil || sibling?.left?.color == .black {
                        sibling?.right?.color = .black
                        sibling?.color = .red
                        if let wUnwrapped = sibling { rotateLeft(wUnwrapped) }
                        sibling = parent?.left
                    }
                    sibling?.color = parent?.color ?? .black
                    parent?.color = .black
                    sibling?.left?.color = .black
                    rotateRight(parent!)
                    node = root
                    parent = nil
                }
            }
        }
        node?.color = .black
    }
    
    // Convenience overload if parent is not separately tracked.
    private func fixAfterDeletion(_ node: Node?) {
        fixAfterDeletion(node, parent: node?.parent)
    }
    
    // MARK: - Sequence Conformance (In-Order Traversal)
    
    public struct Iterator: IteratorProtocol {
        private var stack: [Node] = []
        
        // Marked as private because Node is a private type.
        fileprivate init(root: Node?) {
            var current = root
            while let node = current {
                stack.append(node)
                current = node.left
            }
        }
        
        public mutating func next() -> (Key, Value)? {
            if stack.isEmpty { return nil }
            let node = stack.removeLast()
            let result = (node.key, node.value)
            var current = node.right
            while let successor = current {
                stack.append(successor)
                current = successor.left
            }
            return result
        }
    }
    
    public func makeIterator() -> Iterator {
        return Iterator(root: root)
    }
}
