/// Fixed-size buffer of recent samples, oldest first.
struct History: Equatable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int) {
        self.capacity = capacity
        values.reserveCapacity(capacity + 1)
    }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }
}
