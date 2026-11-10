"""
Strongly connected components helpers.
"""

def sccs(graph):
    """Identify strongly connected components.

    Uses Kosaraju's algorithm as the strategy. This is a non-recursive,
    no-while-loop implementation suitable for Starlark.

    Args:
        graph (dict): A mapping of nodes to their adjacencies.

    Returns:
        A list of lists, where each inner list represents an SCC.
        The components of each SCC are in lexically sorted order.
    """
    parents = {node: [] for node in graph}

    # Each vertex can be entered and finished once, plus one processed edge per neighbor.
    bound = len(graph)
    for node, neighbors in graph.items():
        bound += len(neighbors)
        for neighbor in neighbors:
            parents[neighbor].append(node)

    order = []
    visited = {}
    for root in graph:
        if root in visited:
            continue
        visited[root] = True
        stack = [(root, reversed(graph[root]))]
        for _ in range(bound):
            if not stack:
                break
            node, neighbors = stack[-1]
            if neighbors:
                neighbor = neighbors.pop()
                if neighbor not in visited:
                    visited[neighbor] = True
                    stack.append((neighbor, reversed(graph[neighbor])))
            else:
                order.append(node)
                stack.pop()

    # Second DFS traversal on the transpose graph
    sccs = []

    # The first pass marked every vertex. Consume those marks on the reverse walk.
    for start_node in reversed(order):
        if visited[start_node]:
            visited[start_node] = False
            component = []
            stack = [start_node]

            for _ in range(len(graph)):
                if not stack:
                    break

                current_node = stack.pop()
                component.append(current_node)

                for neighbor in parents[current_node]:
                    if visited[neighbor]:
                        visited[neighbor] = False
                        stack.append(neighbor)

            sccs.append(sorted(component))

    return sccs
