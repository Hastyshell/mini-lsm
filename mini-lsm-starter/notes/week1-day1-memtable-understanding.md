# Week 1 Day 1 Memtable: Understanding Questions and Optimizations

> Chapter: <https://skyzh.github.io/mini-lsm/week1-01-memtable.html#test-your-understanding>
>
> Note: The course does not provide official reference answers. This note records one set of answers and optimization ideas based on the current Week 1 Day 1 implementation in `mini-lsm-starter`.

- [中文版本](#中文版本)
- [English Version](#english-version)

---

## 中文版本

### 当前实现概要

当前 memtable 使用：

```rust
SkipMap<Bytes, Bytes>
```

核心语义：

- `put` 使用 `SkipMap::insert`，同一个 key 在单个 memtable 内只保留最新 value。
- `delete` 不在 `MemTable` 层提供单独 API，而是在存储引擎层写入空 value 作为 tombstone。
- `get` 读取时，如果发现 value 为空，表示该 key 已删除，返回 `None`。
- freeze 后，旧 mutable memtable 被放入 `imm_memtables`，顺序是从新到旧。

### 问题与参考答案

#### 1. 为什么 memtable 不提供 `delete` API？

因为 LSM 中删除通常不是立即物理删除，而是写入一个删除标记，即 tombstone。

在当前实现中，删除被表示为：

```rust
state.memtable.put(key, &[])?;
```

也就是把空 value 写入 memtable。读路径遇到空 value 时返回 `None`。

这样做的好处是：

- 删除操作可以和普通写入走同一条 write path。
- 删除标记可以继续参与 flush、compaction。
- 后续 compaction 时再真正丢弃被删除的数据。

#### 2. memtable 存所有写操作，而不是只存最新版本，有意义吗？

在 Week 1 的单版本 KV 语义下，通常没有必要。

例如：

```text
a -> 1
a -> 2
a -> 3
```

如果这些写入都发生在同一个 memtable 中，用户最终只能读到 `a -> 3`。因此单个 memtable 中只保留最新版本即可。

当前 `SkipMap::insert` 会覆盖同一个 key 的旧 value，符合这个语义。

但在以下场景中，保留多个版本可能有意义：

- MVCC
- snapshot read
- time-travel query
- 事务隔离
- 保留写入历史用于调试或审计

这些属于后续更复杂的设计。

#### 3. 是否可以使用其他数据结构作为 memtable？skiplist 有什么优缺点？

可以。memtable 的数据结构只要能支持以下能力即可：

- point get
- put
- 有序迭代
- range scan
- 合理的并发访问能力

可选方案包括：

- `BTreeMap`
- skiplist
- sorted vector
- ART / radix tree
- hash map + sorted index
- arena-based tree

skiplist 的优点：

- 有序结构，天然支持 range scan。
- 平均插入和查询复杂度为 `O(log n)`。
- `crossbeam_skiplist::SkipMap` 支持并发读写。
- `insert` 只需要 `&self`，因此 `MemTable::put` 不需要额外 mutex。

skiplist 的缺点：

- 指针结构较多，节点通常分散在堆上。
- cache locality 较差。
- 内存额外开销较大。
- scan 时可能频繁跳指针，不如连续内存结构友好。

#### 4. 为什么需要 `state` 和 `state_lock` 的组合？只用 `state.read()` / `state.write()` 可以吗？

`state` 负责保存当前 LSM 状态快照：

```rust
Arc<RwLock<Arc<LsmStorageState>>>
```

它适合做快速读取和快照替换。

`state_lock` 则用于串行化复杂状态修改流程，例如：

- freeze memtable
- flush immutable memtable
- compaction
- manifest 更新
- WAL 创建或同步

理论上只用 `state.write()` 也可以实现，但问题是：

- 锁粒度过大。
- 可能在持有 write lock 时执行 I/O，导致读写请求被长时间阻塞。
- 并发 freeze 时容易出现 race condition。
- 可能把刚创建的空 memtable 立即 freeze 掉。

当前更好的模式是：

1. 使用 `state.read()` 进行快速写入和初步判断。
2. 如果发现 memtable 可能超限，释放 read lock。
3. 获取 `state_lock`，保证只有一个线程在修改 LSM 状态。
4. 重新读取当前 state 并再次检查。
5. 如果当前 memtable 仍然超限，再执行 freeze。

#### 5. 为什么 memtable 的存储顺序和探测顺序重要？如果 key 出现在多个 memtable，应该返回哪个版本？

应该返回最新版本。

当前状态中：

```rust
memtable      // 当前 mutable memtable，最新
imm_memtables // immutable memtable，从新到旧排列
```

因此 get 的探测顺序应该是：

1. 当前 mutable memtable
2. immutable memtables，从新到旧
3. 后续再查询 SSTables，也应遵循版本新旧顺序

如果一个 key 出现在多个 memtable 中，应该返回第一个被探测到的版本，也就是最新版本。

如果最新版本是 tombstone，则应该返回 `None`，并且不能继续向旧 memtable 查找旧值。

#### 6. memtable 的内存布局高效吗？data locality 好吗？

当前布局不算特别高效。

原因：

- skiplist 节点是指针结构，通常分散在堆上。
- `Bytes` 本身是对底层 buffer 的引用计数视图。
- key/value 数据和 skiplist 节点不一定连续存储。
- range scan 时可能频繁跳转内存地址，cache locality 较差。

因此当前实现更偏向简单、并发友好，而不是极致内存效率。

#### 7. `parking_lot` 的读写锁是公平锁吗？如果有 writer 在等待，reader 会怎样？

`parking_lot::RwLock` 采用偏公平 / eventually fair 的策略，并会避免 writer starvation。

当已有 writer 正在等待现有 readers 释放锁时，后续新来的 readers 可能不能一直插队，而是会被阻塞，以便 writer 最终获得锁。

影响：

- writer 不容易被 reader 饿死。
- reader 在 writer 等待期间可能出现延迟。
- 如果在复杂调用链里递归获取 read lock，需要小心潜在死锁风险。

#### 8. freeze memtable 后，是否可能还有线程持有旧 LSM state 并继续写入 immutable memtable？当前方案如何防止？

在当前实现中，写入 memtable 时持有 `state.read()`：

```rust
let state = self.state.read();
state.memtable.put(key, value)?;
let size = state.memtable.approximate_size();
drop(state);
```

freeze 时需要获取 `state.write()` 来替换当前 memtable。

因此，只要某个线程还在旧 memtable 上执行写入并持有 read lock，freeze 就无法获得 write lock。只有这些写入完成并释放 read lock 后，freeze 才能把旧 memtable 移入 `imm_memtables`。

这可以防止：

> memtable 已经被 freeze 成 immutable 后，仍然有线程继续往它写。

需要注意：如果实现改成先 clone state，然后释放 read lock，再写 memtable，就会产生这个风险。

#### 9. 先拿 read lock，再 drop，再拿 write lock，和直接升级 read lock 到 write lock 有什么区别？是否必须升级？升级有什么成本？

区别：

- drop read lock 后再拿 write lock：中间有空窗期，state 可能已经被其他线程修改，因此必须重新检查条件。
- 直接 upgrade：语义更强，中间没有空窗期。

在 mini-lsm 的设计中通常不需要直接升级，因为可以通过：

```text
state_lock + 重新检查当前 state
```

保证正确性。

直接升级的成本：

- 锁实现和调用逻辑更复杂。
- 可能降低并发度。
- 多个线程同时尝试升级时更容易产生复杂等待关系。
- 持有 read lock 等待升级期间，可能阻塞其他状态修改。

因此课程推荐的风格是：

```text
read lock 快速判断
释放 read lock
获取 state_lock
重新读取当前 state
确认条件后再修改
```

### 优化方向

#### 1. 内存布局优化

当前 `SkipMap<Bytes, Bytes>` 的主要问题是内存分散。可以考虑：

- 使用 arena allocator 分配节点和 key/value，减少碎片。
- 对小 key/value 做 inline storage，减少额外堆分配。
- freeze 后将 immutable memtable 转成更紧凑的 sorted vector 或 block layout。
- 使用 prefix compression 降低 key 的重复存储成本。
- 使用更接近 SSTable block 的内存格式，提升 flush 和 scan 效率。

#### 2. 并发控制优化

当前设计已经避免了在普通 put 上使用 memtable mutex，但仍可以继续优化：

- 缩小 `state.read()` 的持有范围，但不能在释放 read lock 后继续写旧 memtable。
- 将可能涉及 I/O 的操作放在 `state.write()` 外部。
- 所有状态变更统一经过 `state_lock`，避免并发 freeze / flush / compaction 互相干扰。
- 为 freeze / flush 增加更明确的状态检查，避免空 memtable 被 freeze。

#### 3. tombstone 处理优化

当前用空 value 表示 tombstone，简单但有局限：

- 无法区分真实空 value 和删除标记。
- 后续如果允许用户写入空 value，需要引入显式 value type。

可优化为：

```rust
enum Value {
    Put(Bytes),
    Delete,
}
```

或者在编码层增加 record type。

#### 4. approximate size 统计优化

当前 approximate size 每次 put 都累加：

```rust
key.len() + value.len()
```

如果同一个 key 被覆盖多次，也会重复计入。这符合课程要求中的近似统计，但不精确。

可优化方向：

- 插入前检查旧 value，计算 size delta。
- 把 skiplist 节点开销、`Bytes` 元数据开销也计入估算。
- 分离 logical data size 和 estimated memory usage。

不过精确统计会增加并发和性能成本，是否值得取决于使用场景。

#### 5. 读路径优化

当前 get 会依次查找 mutable memtable 和 immutable memtables。后续可以考虑：

- 为 SSTable 使用 bloom filter。
- 为 memtable 或 immutable memtable 增加 key range metadata。
- 对 immutable memtable 维护更紧凑的 searchable structure。
- 在多层 SST 查询中利用 level 的有序性减少无效查找。

#### 6. WAL 与 freeze 流程优化

后续启用 WAL 后，需要注意：

- 创建新 WAL 文件可能有 I/O，尽量不要放在 `state.write()` 内。
- freeze 旧 memtable 前后需要正确 sync WAL。
- manifest 记录和目录 sync 需要和状态变更保持一致。
- crash recovery 时需要根据 WAL 恢复 memtable。

#### 7. 面向 MVCC 的优化

如果进入 Week 3 的 MVCC 设计，memtable 的 key 会从单纯 user key 变成带 timestamp 的 internal key。

需要考虑：

- 同一 user key 的多个版本排序。
- snapshot read 如何选择可见版本。
- tombstone 如何带 timestamp。
- compaction 如何根据 watermark 清理旧版本。

### 小结

当前 Week 1 Day 1 的实现重点是：

- 用 skiplist 实现并发友好的有序 memtable。
- 用空 value 表示删除 tombstone。
- 单个 memtable 内只保留同 key 最新值。
- 读路径按从新到旧的顺序查找。
- freeze 流程用 `state_lock` 串行化状态修改，并通过重新检查避免并发 race。

后续优化主要围绕：

- 内存布局
- 并发锁粒度
- tombstone 表达
- size 统计精度
- 读路径过滤
- WAL 与 crash recovery
- MVCC 多版本支持

---

## English Version

### Current Implementation Summary

The current memtable is implemented with:

```rust
SkipMap<Bytes, Bytes>
```

Core semantics:

- `put` uses `SkipMap::insert`, so a single memtable only keeps the latest value for the same key.
- `delete` is not exposed as a separate `MemTable` API. Instead, the storage engine writes an empty value as a tombstone.
- `get` treats an empty value as a deletion marker and returns `None`.
- After freezing, the old mutable memtable is moved into `imm_memtables`, ordered from newest to oldest.

### Questions and Reference Answers

#### 1. Why does the memtable not provide a `delete` API?

Because deletion in an LSM tree is usually not an immediate physical removal. Instead, it is represented by writing a deletion marker, also known as a tombstone.

In the current implementation, deletion is represented as:

```rust
state.memtable.put(key, &[])?;
```

That means an empty value is written into the memtable. The read path returns `None` when it sees an empty value.

Benefits:

- Delete operations share the same write path as normal puts.
- Tombstones can participate in flush and compaction.
- The deleted data can be physically discarded later during compaction.

#### 2. Does it make sense for a memtable to store all write operations instead of only the latest version?

For the single-version key-value semantics in Week 1, usually no.

For example:

```text
a -> 1
a -> 2
a -> 3
```

If all writes happen in the same memtable, the user can only observe `a -> 3`. Therefore, keeping only the latest value for each key is sufficient.

The current `SkipMap::insert` overwrites the old value for the same key, which matches this behavior.

However, keeping multiple versions can be useful for:

- MVCC
- snapshot reads
- time-travel queries
- transaction isolation
- retaining write history for debugging or auditing

Those are more advanced designs introduced later.

#### 3. Can other data structures be used as the memtable? What are the pros and cons of skiplist?

Yes. A memtable data structure only needs to support:

- point get
- put
- ordered iteration
- range scan
- reasonable concurrent access

Possible alternatives include:

- `BTreeMap`
- skiplist
- sorted vector
- ART / radix tree
- hash map + sorted index
- arena-based tree

Pros of skiplist:

- It is ordered and naturally supports range scans.
- Average insertion and lookup complexity is `O(log n)`.
- `crossbeam_skiplist::SkipMap` supports concurrent reads and writes.
- `insert` only requires `&self`, so `MemTable::put` does not need an extra mutex.

Cons of skiplist:

- It is pointer-heavy, and nodes are usually scattered on the heap.
- It has poor cache locality compared with contiguous layouts.
- It has relatively high memory overhead.
- Range scans may involve many pointer jumps.

#### 4. Why do we need both `state` and `state_lock`? Can we only use `state.read()` / `state.write()`?

`state` stores the current LSM state snapshot:

```rust
Arc<RwLock<Arc<LsmStorageState>>>
```

It is suitable for fast reads and snapshot replacement.

`state_lock` serializes complex state modifications, such as:

- freezing a memtable
- flushing immutable memtables
- compaction
- manifest updates
- WAL creation or synchronization

Using only `state.write()` is theoretically possible, but it has problems:

- The lock granularity is too coarse.
- I/O may happen while holding the write lock, blocking all readers and writers for too long.
- Concurrent freeze operations can introduce race conditions.
- A newly created empty memtable might be frozen immediately by another thread.

A better pattern is:

1. Use `state.read()` for the fast write path and initial size check.
2. Drop the read lock if the memtable may exceed the size limit.
3. Acquire `state_lock` so only one thread can modify the LSM state.
4. Read the current state again and recheck the condition.
5. Freeze only if the current memtable still exceeds the limit.

#### 5. Why does the order of storing and probing memtables matter? Which version should be returned if a key appears in multiple memtables?

The latest version should be returned.

The current state layout is:

```rust
memtable      // the current mutable memtable, newest
imm_memtables // immutable memtables, from newest to oldest
```

Therefore, the `get` probing order should be:

1. the current mutable memtable
2. immutable memtables, from newest to oldest
3. later, SSTables according to their version and level order

If a key appears in multiple memtables, the first version found in this order should be returned.

If the newest version is a tombstone, the result should be `None`, and the read path must not continue looking for older values.

#### 6. Is the memory layout of the memtable efficient? Does it have good data locality?

Not particularly.

Reasons:

- Skiplist nodes are pointer-based and usually scattered on the heap.
- `Bytes` is a reference-counted view into an underlying buffer.
- Key/value data and skiplist nodes are not necessarily stored contiguously.
- Range scans may jump across memory locations frequently, resulting in poor cache locality.

So the current implementation favors simplicity and concurrency rather than optimal memory efficiency.

#### 7. Is `parking_lot::RwLock` fair? What happens to readers if a writer is waiting?

`parking_lot::RwLock` uses an eventually fair policy and tries to avoid writer starvation.

When a writer is waiting for existing readers to release the lock, new readers may not be allowed to keep bypassing the writer. They may be blocked so that the writer can eventually acquire the lock.

Implications:

- Writers are less likely to starve.
- Readers may experience latency when a writer is waiting.
- Recursive read locking in complex call paths should be handled carefully because it may cause deadlock-like situations.

#### 8. After freezing a memtable, can some threads still hold the old LSM state and write into immutable memtables? How does the current solution prevent this?

In the current implementation, writes hold `state.read()` while writing to the memtable:

```rust
let state = self.state.read();
state.memtable.put(key, value)?;
let size = state.memtable.approximate_size();
drop(state);
```

Freezing needs `state.write()` to replace the current memtable.

Therefore, as long as a thread is still writing to the old memtable while holding the read lock, freeze cannot acquire the write lock. The old memtable is only moved into `imm_memtables` after these writes finish and release the read lock.

This prevents:

> A memtable has already become immutable, but another thread still writes into it.

Be careful: if the implementation clones the state, drops the read lock, and then writes to the old memtable, this protection would be lost.

#### 9. What is the difference between dropping a read lock and then acquiring a write lock versus directly upgrading the read lock? Is upgrading necessary, and what is the cost?

Differences:

- Dropping the read lock and then acquiring the write lock creates a gap. The state may be changed by another thread, so the condition must be rechecked.
- Direct upgrade gives stronger semantics because there is no such gap.

In mini-lsm, direct upgrade is usually unnecessary because correctness can be achieved with:

```text
state_lock + recheck the current state
```

Costs of direct upgrade:

- More complex lock implementation and call logic.
- Potentially lower concurrency.
- Multiple threads trying to upgrade at the same time can create complicated waiting relationships.
- Holding a read lock while waiting to upgrade may block other state modifications.

The recommended style in this course is:

```text
quick check with read lock
drop read lock
acquire state_lock
read the current state again
modify only after confirming the condition
```

### Optimization Directions

#### 1. Memory layout optimization

The main issue with `SkipMap<Bytes, Bytes>` is scattered memory layout. Possible improvements:

- Use an arena allocator for nodes and key/value data to reduce fragmentation.
- Inline small keys and values to avoid extra heap allocations.
- Convert frozen immutable memtables into a compact sorted vector or block layout.
- Use prefix compression to reduce duplicated key bytes.
- Use an in-memory layout closer to SSTable blocks to improve flush and scan performance.

#### 2. Concurrency control optimization

The current design already avoids a memtable-level mutex on normal puts, but it can still be improved:

- Reduce the scope of `state.read()`, but never write to an old memtable after releasing the read lock.
- Move I/O operations outside `state.write()` whenever possible.
- Route all state modifications through `state_lock` to avoid interference between freeze, flush, and compaction.
- Add clearer state checks for freeze and flush to avoid freezing empty memtables.

#### 3. Tombstone representation optimization

Using an empty value as a tombstone is simple but limited:

- It cannot distinguish a real empty value from a deletion marker.
- If users are allowed to write empty values later, an explicit value type is needed.

One possible representation is:

```rust
enum Value {
    Put(Bytes),
    Delete,
}
```

Alternatively, add a record type in the encoded format.

#### 4. Approximate size accounting optimization

The current approximate size is increased on every put:

```rust
key.len() + value.len()
```

If the same key is overwritten multiple times, it is counted multiple times. This matches the course requirement for approximate accounting, but it is not precise.

Possible improvements:

- Check the old value before insertion and calculate the size delta.
- Include skiplist node overhead and `Bytes` metadata overhead in the estimate.
- Separate logical data size from estimated memory usage.

However, precise accounting increases concurrency and performance costs, so it depends on the use case.

#### 5. Read path optimization

The current `get` checks the mutable memtable and immutable memtables sequentially. Later optimizations may include:

- Add bloom filters for SSTables.
- Add key range metadata for memtables or immutable memtables.
- Maintain a more compact searchable structure for immutable memtables.
- Use level ordering in SSTables to reduce unnecessary lookups.

#### 6. WAL and freeze flow optimization

After WAL is enabled, pay attention to:

- Creating a new WAL file may involve I/O, so it should not happen inside `state.write()` if avoidable.
- The old memtable's WAL must be synced correctly around freeze.
- Manifest records and directory sync must stay consistent with state updates.
- Crash recovery must rebuild memtables from WAL files.

#### 7. MVCC-oriented optimization

In Week 3, the memtable key changes from a plain user key to an internal key with timestamp.

Things to consider:

- Ordering multiple versions of the same user key.
- Selecting visible versions for snapshot reads.
- Representing tombstones with timestamps.
- Using watermarks during compaction to clean old versions.

### Summary

The key ideas of the current Week 1 Day 1 implementation are:

- Use a skiplist for a concurrent ordered memtable.
- Use an empty value as a deletion tombstone.
- Keep only the latest value for each key in a single memtable.
- Probe memtables from newest to oldest in the read path.
- Use `state_lock` to serialize state modifications during freeze, and recheck conditions to avoid races.

Future optimizations mainly focus on:

- memory layout
- lock granularity
- tombstone representation
- size accounting precision
- read path filtering
- WAL and crash recovery
- MVCC multi-version support
