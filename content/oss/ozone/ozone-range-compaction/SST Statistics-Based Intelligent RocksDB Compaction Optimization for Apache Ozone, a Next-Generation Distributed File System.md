---
tags:
  - ozone
---

[Pull Request of this Design](https://github.com/apache/ozone/pull/8178/files?short_path=b902313#diff-b90231324681b8883d21437dff645bec304f126fc9f778a57348954c75858b9d)

## TODO

```tasks
not done
path includes {{query.file.path}}
```

## Rough Thought

研究了一下 TiKV 跟 rocksDB compaction 我對目前的 OM compaction 有些想法
1. TiKV 也是跑個 background task 去做 compaction.
2. 如果直接對整個 cf 做 compaction 好像會對 online 效能有影響 (large write amplification)
3. 可以用 SST 內建的 TableProperties 去看 SST file 的 num_entries 跟 num_deletion, 但是那兩個指標是單指操作數, 沒有對 key 去重複
4. TiKV 有自己寫個 custom 的 MVCTablePropertiesCollector, 裡面有作去重複, 所以更精準, 但是目前 Java API 似乎是不支援自定義的 TablePropertiesCollector💩 所以只能勉為其難的用內建的的統計數據
5. TiKV 因為會對 key range 做邏輯上的切分(table region, 預設每個 region 不超過 256 MB), 所以可以直接對已知的 ranges 慢慢掃 慢慢 compact
	- [compaction key range paging](https://github.com/tikv/tikv/pull/2631/files#diff-49d2597226cac1291163478f47bee5d4530bd4b9b84d322059e8afaf7dd3dedcR1896-R1938)
	- [check if each key range need compaction](https://github.com/tikv/tikv/pull/2631/files#diff-52d5655c2ce5a05afae67d216f55e98a1d71c971e1869628b7ebe387dda90a37R203-R217)

那如果要把這個邏輯套用在 Ozone Manager 身上的話, 因為 OM 不是 distributed KV, 所以沒有 key range 的概念, 唯一能做邏輯劃分的 key range 只有 bucket prefix (file table), 但有個更棒的點是如果是 FSO bucket, 我們還可以根據 directory parent id 去做更細的 key range 劃分.

所以我覺得, For KeyTable Compaction, 可以 for each bucket 去 compaction, 然後可以記個 next_bucket 去做 paging. For Directory related Table, 也可以 for each bucket 去做 compaction, 但如果發現這個 bucket 太大的話, 就再去對 ordered parent_id  的 key range 去做 compaction, 所以會需要兩個  paging key: next_bucket, next_parent_id

- [TableProperties class](https://github.com/facebook/rocksdb/blob/main/java/src/main/java/org/rocksdb/TableProperties.java#L12)
- [`public Map<String, TableProperties> getPropertiesOfTablesInRange(final ColumnFamilyHandle columnFamilyHandle, final List<Range> ranges)`](https://github.com/facebook/rocksdb/blob/934cf2d40dc77905ec565ffec92bb54689c3199c/java/src/main/java/org/rocksdb/RocksDB.java#L4575)
- [Range Class](https://github.com/facebook/rocksdb/blob/934cf2d40dc77905ec565ffec92bb54689c3199c/java/src/main/java/org/rocksdb/Range.java)
Java 目前有一些支援的 API 可以讓我們做到上面講的事

## Short Introduction

Use the `numEntries` and `numDeletion` in [TableProperties](https://github.com/facebook/rocksdb/blob/main/java/src/main/java/org/rocksdb/TableProperties.java#L12) which stores statistics for each SST as "guidance" to determine how to split tables into finer ranges for compaction.

## Motivation

Our current approach of compacting entire column families directly would significantly impact online performance through excessive write amplification. After researching TiKV and RocksDB compaction mechanisms, it's clear we need a more sophisticated solution that better balances maintenance operations with user workloads.

TiKV runs background tasks for compaction and logically splits key ranges into table regions (with default size limits of 256MB per region), allowing gradual scanning and compaction of known ranges. While we can use the built-in `TableProperties` in SST files to check metrics like `num_entries` and `num_deletion`, these only represent operation counts without deduplicating keys. TiKV addresses this with a custom `MVCTablePropertiesCollector` for more accurate results, but unfortunately, the Java API doesn't currently support custom collectors, forcing us to rely on built-in statistics.

For the Ozone Manager implementation, we face a different challenge since OM lacks the concept of size-based key range splits. The most logical division we can use is the bucket prefix (file table). For FSO buckets, we can further divide key ranges based on directory `parent_id`, enabling more granular and targeted compaction that minimizes disruption to ongoing operations.

By implementing bucket-level compaction with proper paging mechanisms like `next_bucket` and potentially `next_parent_id` for directory-related tables, we can achieve more efficient storage utilization while maintaining performance. The Java APIs currently provide enough support to implement these ideas, making this approach viable for Ozone Manager.

## Proposed Changes

### RocksDB Java API Used

- [`public Map<String, TableProperties> getPropertiesOfTablesInRange(final ColumnFamilyHandle columnFamilyHandle, final List<Range> ranges)`](https://github.com/facebook/rocksdb/blob/934cf2d40dc77905ec565ffec92bb54689c3199c/java/src/main/java/org/rocksdb/RocksDB.java#L4575)
    - Given a list of `Range`, returns a map of `TableProperties` in these ranges.
- [TableProperties](https://github.com/facebook/rocksdb/blob/main/java/src/main/java/org/rocksdb/TableProperties.java#L12)
    - Statistical data for one SST file.
- [Range](https://github.com/facebook/rocksdb/blob/934cf2d40dc77905ec565ffec92bb54689c3199c/java/src/main/java/org/rocksdb/Range.java)
    - Contains one start [slice](https://javadoc.io/doc/org.rocksdb/rocksdbjni/6.20.3/org/rocksdb/Slice.html) and one end slice.

### New Configuration Set

Introduce four new configuration strings:
- `bucket_compact_check_interval`: Interval (ms) to check whether to start compaction for a region.
- `bucket_compact_max_entries_sum`: Upper bound of num_entries sum from all SST files in one compaction range. Default value is 1000000.
- `bucket_compact_tombstone_percentage`: Only compact range when `num_entries * tombstone_percentage / 100 <= num_deletion`. Default value is 30.
- `bucket_compact_min_tombstones`: Minimum number of tombstones to trigger manual compaction. Default value is 10000.

### Create Compactor For Each Table

Create new compactor instances for each table, including `KEY_TABLE`, `DELETED_TABLE`, `DELETED_DIR_TABLE`, `DIRECTORY_TABLE`, `FILE_TABLE`, and `MULTIPARTINFO_TABLE`. Run these background workers using a scheduled executor with configured interval and a random start time to spread out the workload.

### (Optional) CacheIterator Support for Seek with Prefix

1. The current interface of bucketIterator in `OMMetadataManager` returns a CacheIterator for bucket table (with `FULL_TABLE_CACHE` in non-snapshot metadata manager), but the cache iterator currently doesn't support seeking with prefix. Since FullTableCache uses ConcurrentSkipList as cache, we can support seeking with prefix in $O(\log{n})$ time.
    - If seeking with prefix is called on partial table cache, it should raise an unsupported operation error.
2. However, since BucketIterator doesn't require high performance, using the seekable table iterator in `TypedTable` might be sufficient.

### Support RocksDatabase to get range stats

```java
public class KeyRange {
    private final String startKey;
    private final String endKey;

    public Range toRocksRange() {
        return new Range(new Slice(stringToBytes(startKey)), new Slice(stringToBytes(endKey)));
    }
}

public class KeyRangeStats {
    // Can support more fields in the future
    int numEntries;
    int numDeletion;

    public static KeyRangeStats fromTableProperties(TableProperties properties) {
        ...
    }

    // Make this mergeable for continuous ranges
    public void add(KeyRangeStats other) {
        this.numEntries += other.numEntries;
        this.numDeletion += other.numDeletion;
    }
}

public class RocksDatabase {
    List<KeyRangeStats> getRangeStats(ColumnFamilyHandle columnFamilyHandle, KeyRange range) {
        Map<String, TableProperties> tableProperties = getPropertiesOfTablesInRange(columnFamilyHandle, range.toRocksRange());
        List<KeyRangeStats> stats = new ArrayList<>();
        for (TableProperties properties : tableProperties.values()) {
            stats.add(KeyRangeStats.fromTableProperties(properties));
        }
        return stats;
    }
}
```

### Two Types of Compactors

#### Compactor for OBS and Legacy Layout

For the following tables, since the bucket key prefix is consecutive, if there are consecutive buckets that need compaction, merge them. Note that we still need to keep the range key sum below the configured limit.

| Column Family  | Key                              | Value             |
| -------------- | -------------------------------- | ----------------- |
| `keyTable`     | `/volumeName/bucketName/keyName` | `KeyInfo`         |
| `deletedTable` | `/volumeName/bucketName/keyName` | `RepeatedKeyInfo` |

Pseudo code:

```java
class BucketCompactor {
    private final OMMetadataManager metadataMgr;

    // Pagination key
    // These fields would have values if the compaction range of the previous bucket is too large, 
    // and the range of that bucket is split down.
    // This could also be encapsulated to be shared between OBS and FSO compactor
    private BucketInfo nextBucket;
    private String nextKey;

    private Iterator<Map.Entry<CacheKey<String>, CacheValue<OmBucketInfo>>> getBucketIterator() {
        iterator = metadataMgr.getBucketIterator(nextBucket);
        // Reset if iterator reaches the end
        if (!iterator.hasNext()) iterator.seekToFirst();
        return iterator;
    }

    // Run with scheduled executor
    private void run() {
        iterator = getBucketIterator();
        List<Range> ranges = collectNeedCompactionRanges(iterator, db, threshold);
    }

    // Check the SST properties for each bucket, and compact a bucket if it contains too many RocksDB tombstones.
    // Merge multiple neighboring buckets that need compacting into a single range.
    private List<Range> collectNeedCompactionRanges(Iterator bucketIterator, DBstore db, int minTombstoneThreshold, int maxEntriesSum) {
        List<Range> ranges = new ArrayList<>();

        while (bucketIterator.hasNext()) {
            if (nextBucket == null) {
                // Handle pagination
            }

            Map.Entry<CacheKey<String>, CacheValue<OmBucketInfo>> entry = bucketIterator.next();
            if (/* Bucket range not too large or only one SST covers the whole bucket */) {
                // See if the range of this bucket needs compaction
            } else {
                // 1. Use binary search to find the **end key** of the bucket that's below the numEntriesSum limit,
                //    where the sum of numEntries of all SSTs in this range[startKey, **endKey**] is below the limit
                // 2. See if the range of this bucket needs compaction
                // 3. Set pagination key to the **end key**
            }

            // Merge ranges if there are continuous ranges that need compaction and don't exceed the maxEntriesSum limit
        }
    }

    private boolean needCompact(KeyRangeStats mergedRangeStats, int minTombstoneThreshold, int maxEntriesSum) {
        if (mergedRangeStats.numDeletion < minTombstoneThreshold) {
            return false;
        }

        return mergedRangeStats.numEntries * tombstone_percentage / 100 <= mergedRangeStats.numDeletion;
    }
}
```

#### Compactor for FSO Layout

For the following tables, since the bucket key prefix is **not** consecutive, we won't merge different key ranges from different buckets.

| Column Family     | Key                                            | Value     |
| ----------------- | ---------------------------------------------- | --------- |
| `directoryTable`  | `/volumeId/bucketId/parentId/dirName`          | `DirInfo` |
| `fileTable`       | `/volumeId/bucketId/parentId/fileName`         | `KeyInfo` |
| `deletedDirTable` | `/volumeId/bucketId/parentId/dirName/objectId` | `KeyInfo` |

Pseudo code:

```java
class FSOBucketCompactor {
    // Share the same logic with OBS compactor
    // **But don't merge different key ranges from different buckets**
}
```

## Prevent overloading of RocksDB

Compactors should send the compaction request(including the range and column family) to one thread-safe queue first, and the compaction worker will pick up the request from the queue sequentially.

## Test Plan

- Unit tests
- Need some benchmarks

### Benchmark

#### Manual Compaction on Range (This proposal)

#### Built-in `CompactOnDeletionCollector` with different argument sets

`CompactOnDeletionCollector` is a built-in collector in RocksDB that marks an SST file as needing compaction when the number of deletions is greater than a threshold in a specific sliding window.

## Documentation Plan

We should set some heuristics based on benchmark: https://cs-people.bu.edu/mathan/publications/edbt25-wei.pdf

- `bucket_compact_check_interval`: Interval (ms) to check whether to start compaction for a region.
- `bucket_compact_max_entries_sum`: Upper bound of num_entries sum from all SST files in one compaction range. Default value is 1000000.
- `bucket_compact_tombstone_percentage`: Only compact range when `num_entries * tombstone_percentage / 100 <= num_deletion`. Default value is 30.
- `bucket_compact_min_tombstones`: Minimum number of tombstones to trigger manual compaction. Default value is 10000.

## Additional Note

1. Once RocksDB Java supports custom `TablePropertiesCollector`, we should leverage that to do finer key range splits.

## Record

### 2025/05/12

完成:
- [Support CF key range compaction and SST properties retrieval for rocksDB](https://github.com/peterxcli/ozone/pull/2/commits/5694fed147410568e1c0c4073d68a0710f83209c "Support CF key range compaction and SST properties retrieval for rocksDB")
- [Support cacheIterator method with startKey for full table cache](https://github.com/peterxcli/ozone/pull/2/commits/6b1ac84a2b077969f1f0279d39eebf0c6c214fe8 "Support cacheIterator method with startKey for full table cache")

### 2025/05/13

完成:
- [Add range compaction service skeleton](https://github.com/peterxcli/ozone/pull/2/commits/c393b3c0aa6fdf9dd11c840a3a3deb73f8ef3105 "Add range compaction service skelton")

遇到的問題:
- [x] 先關注在 `keyTable` 上, 現在我們可以拿到同個 bucket prefix 內的所有 SST files 了, 但假如經過累加之後發現這個 bucket 裡面的 keys 數量太多了, 那勢必要把這個 bucket key range 切成更小的 range, 那如果要切 range 的話就需要知道那些 SST file 內他們各自的 key 的邊界, 然後再透過一些策略去看怎麼切分, 可能什麼 interval tree, segment tree 可以幫助這種區間上的計算, 不過那是後話 ✅ 2025-06-09
      如果需要拿到一個 SST 的 `startKey` and `endKey`, 目前只能 call `RocksDatabase#getLiveFilesMetaData()` 去拿當前的 FileMetadata list 然後去看哪個 file name match target SST file name, 再從那個 object 裡面拿 startKey and endKey. FileMetadata list 的數量級: 4 billion keys 的話大概會有 10,000 個 SST file, `RocksDatabase#getLiveFilesMetaData()` 也不支援任何 predicate... key 一多, 每次都要 list metadata files 感覺有點浪費.
      不然就是要透過 SSTFileReader 去讀 SST filename 然後用 `seekToFirst` & `seekToLast` 去拿 startKey and endKey. 可是這樣的話, 因為 tombstone entries 有可能超過 iterator seek 出來的範圍, 有可能切割到錯誤的 range boundary 上.
      是有一個 `ManagedRawSSTFileReader` 可以讀含有 tombstone 的所有 entries 可以目前他支援把整個 SST 內的 entries (含 tombstone) 從頭到尾讀出來, 但我們只需要頭尾的 entries 而已... 也有點浪費, 如果要讓他支援 seek to first/last 還有去改 c++ code and JNI, 我目前改不動XDD
### 2025/5/18

完成:
- [Minor refactor](https://github.com/peterxcli/ozone/pull/2/commits/604e1cc4011d18e2187b06712737929588ba369a)

### 2025/5/19

- [x] Add a function to prepare ranges first, start from `nextKey` or `currentBucketBoundary`. This can be done by getting the live file metadata list, then use `getPropsOfTableInRange` to retrieve SSTs in range `[nextKey, currentBucketBoundary]` or `[currentBucket, currentBucketBoundry]`, and if there are too many entries in these ranges, we need to further spilt them into smaller one, them save spilt point in `nextKey` for next round to use. ✅ 2025-06-09
	In `collectRangesNeedingCompaction`, it call the previous
	
	**The thing is how to spilt the big range down is good????????????** I totally have no idea...

### 2025/5/24

- [x] log a warning when the entries num in a single SST exceed the max compaction entries config ✅ 2025-06-09

### 2025/5/31

- Custer

Build dist
```bash
mvn clean install -Drocks_tools_native -DskipTests -Pgo-offline -DskipShade
```

Start cluster (Could run in another shell)
```bash
z hadoop-ozone/dist/target/ozone-2.1.0-SNAPSHOT/compose/ozone
export COMPOSE_FILE=docker-compose.yaml:monitoring.yaml:profiling.yaml
OZONE_DATANODES=3 ./run.sh -d

# Follow om's log
docker compose logs om -f
```

Restart Cluster(this can use to apply new build directly)
```
z hadoop-ozone/dist/target/ozone-2.1.0-SNAPSHOT/compose/ozone
export COMPOSE_FILE=docker-compose.yaml:monitoring.yaml:profiling.yaml
cd .. && cd ozone && docker compose restart
```

- Cluster configuration
`hadoop-ozone/dist/target/ozone-2.1.0-SNAPSHOT/etc/hadoop/ozone-site.xml`
```xml
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>	
	<property>
	    <name>hadoop.hdds.db.rocksdb.logging.enabled</name>
	    <value>true</value>
	</property>

	<property>
	    <name>ozone.metastore.rocksdb.statistics</name>
	    <value>ALL</value>
  </property>

  <property>
    <name>ozone.default.bucket.layout</name>
    <value>OBJECT_STORE</value>
  </property>
</configuration>

```

- Build RocksDB
https://github.com/peterxcli/rocksdb/releases/tag/v7.7.3.2
```bash
make jclean clean rocksdbjavastaticreleasedocker CMAKE_POLICY_VERSION_MINIMUM=3.5 J=8 ROCKSDB_JAVA_VERSION=7.7.3.2 # (check if rocksdbjava_javadocs_jar has been added to dependency)

make rocksdbjavastaticpublishgithub
```

### 2025/06/3

- [ ] swamin 說可以把 patch 寫在 rocksdb tools 那邊, 我想說之後如果成效不錯的話再試試看用他說的方式交付回去好了, 現在先用我 build 好放在 github package 那的 jni 測試: https://github.com/peterxcli/rocksdb/packages/2527059
	- 感覺是可以 就調用一些透過 jdb_handle 拿到的 db instance 的 public method 去拿資料就好

```cpp
auto* db = reinterpret_cast<ROCKSDB_NAMESPACE::DB*>(jdb_handle);
```

### 2025/6/6

- Script to ingest keys to om rocksdb:
```
freon ommg

ozone freon ommg --operation CREATE_KEY -n 1 -t 100 --size=0 --volume s3v  --bucket bucket1
ozone freon ommg --operation CREATE_FILE -n 1 -t 100 --size=0 --volume s3v  --bucket bucket1
```


```bash
ozone sh volume create vol1
ozone sh bucket create /vol1/bucket1 --layout OBJECT_STORE

ozone freon ommg --operation CREATE_KEY -n 50000000 -t 100 --size=0 --volume vol1 --bucket bucket1
```

### 2025/6/7

```java

```

### 2025/6/8

#### 100M-20:8:1:enable-range-compaction:disable-peridioc-full-compaction

1. append to: `hadoop-ozone/dist/target/ozone-2.1.0-SNAPSHOT/compose/ozone/docker-config`
```
OZONE-SITE.XML_ozone.om.range.compaction.service.enabled=true
OZONE-SITE.XML_ozone.om.range.compaction.service.max.compaction.entries=3000000
```

2. start testing with mixed workload

```bash
ozone sh volume create vol1
ozone sh bucket create /vol1/bucket1 --layout OBJECT_STORE
ozone freon omkeybench -n 100000000 -t 100 --size=0 --volume vol1 --bucket bucket1 --weights create:20,delete:8,list:1 --max-live-keys 25000
```

3. result
```bash
 84.95% |?????????????????????????????      |  84952175/100000000 Time: 14:41:27|  live=25000/25000 created=58592882 deleted=23415201 [LIMIT_REACHED] CREATE: rate 1584 max 1827 DELETE: rate 640 max 765 LIST: rate 67 max 117^C6/10/25, 5:45:13?PM ============================================================

-- Timers ----------------------------------------------------------------------
CREATE
             count = 58593186
         mean rate = 1107.92 calls/second
     1-minute rate = 971.33 calls/second
     5-minute rate = 1092.89 calls/second
    15-minute rate = 1111.86 calls/second
               min = 41.27 milliseconds
               max = 2299.82 milliseconds
              mean = 103.17 milliseconds
            stddev = 222.31 milliseconds
            median = 51.70 milliseconds
              75% <= 56.23 milliseconds
              95% <= 635.08 milliseconds
              98% <= 975.32 milliseconds
              99% <= 1092.38 milliseconds
            99.9% <= 2161.26 milliseconds
DELETE
             count = 23430361
         mean rate = 443.04 calls/second
     1-minute rate = 387.40 calls/second
     5-minute rate = 437.36 calls/second
    15-minute rate = 444.54 calls/second
               min = 17.24 milliseconds
               max = 2133.06 milliseconds
              mean = 47.69 milliseconds
            stddev = 153.30 milliseconds
            median = 24.91 milliseconds
              75% <= 27.03 milliseconds
              95% <= 33.94 milliseconds
              98% <= 595.95 milliseconds
              99% <= 1015.15 milliseconds
            99.9% <= 2133.06 milliseconds
LIST
             count = 2929047
         mean rate = 55.39 calls/second
     1-minute rate = 48.36 calls/second
     5-minute rate = 54.45 calls/second
    15-minute rate = 55.52 calls/second
               min = 2.71 milliseconds
               max = 224.15 milliseconds
              mean = 35.20 milliseconds
            stddev = 11.97 milliseconds
            median = 34.10 milliseconds
              75% <= 37.52 milliseconds
              95% <= 44.80 milliseconds
              98% <= 50.49 milliseconds
              99% <= 53.08 milliseconds
            99.9% <= 218.51 milliseconds


Total execution time (sec): 52888
Failures: 0
Successful executions: 84952642
```
#### 100M-20:8:1:disable-range-compaction:disable-peridioc-full-compaction

1. remove all additional config in: `hadoop-ozone/dist/target/ozone-2.1.0-SNAPSHOT/compose/ozone/docker-config`
2. start testing with mixed workload
```bash
ozone sh volume create vol1
ozone sh bucket create /vol1/bucket1 --layout OBJECT_STORE
ozone freon omkeybench -n 100000000 -t 100 --size=0 --volume vol1 --bucket bucket1 --weights create:20,delete:8,list:1 --max-live-keys 25000
```

3. result

```bash
 86.22% |?????????????????????????????     |  86216505/100000000 Time: 14:57:58|  live=25000/25000 created=59461613 deleted=23765495 [LIMIT_REACHED] CREATE: rate 1362 max 1833 DELETE: rate 519 max 781 LIST: rate 64 max

-- Timers ----------------------------------------------------------------------
CREATE
             count = 59462027
         mean rate = 1103.67 calls/second
     1-minute rate = 1310.73 calls/second
     5-minute rate = 1161.31 calls/second
    15-minute rate = 1105.73 calls/second
               min = 41.91 milliseconds
               max = 1399.99 milliseconds
              mean = 59.52 milliseconds
            stddev = 84.32 milliseconds
            median = 50.06 milliseconds
              75% <= 54.26 milliseconds
              95% <= 62.51 milliseconds
              98% <= 72.90 milliseconds
              99% <= 244.92 milliseconds
            99.9% <= 1356.15 milliseconds
DELETE
             count = 23780956
         mean rate = 441.40 calls/second
     1-minute rate = 524.92 calls/second
     5-minute rate = 464.70 calls/second
    15-minute rate = 442.04 calls/second
               min = 17.94 milliseconds
               max = 1375.04 milliseconds
              mean = 31.57 milliseconds
            stddev = 63.75 milliseconds
            median = 24.31 milliseconds
              75% <= 26.45 milliseconds
              95% <= 30.87 milliseconds
              98% <= 59.64 milliseconds
              99% <= 191.86 milliseconds
            99.9% <= 739.98 milliseconds
LIST
             count = 2974075
         mean rate = 55.20 calls/second
     1-minute rate = 64.50 calls/second
     5-minute rate = 57.72 calls/second
    15-minute rate = 55.15 calls/second
               min = 1.79 milliseconds
               max = 243.03 milliseconds
              mean = 32.84 milliseconds
            stddev = 11.82 milliseconds
            median = 31.56 milliseconds
              75% <= 35.07 milliseconds
              95% <= 42.64 milliseconds
              98% <= 46.73 milliseconds
              99% <= 49.98 milliseconds
            99.9% <= 190.79 milliseconds


Total execution time (sec): 53879
Failures: 0
Successful executions: 86217148
```
#### 100M-20:8:1:disable-range-compaction:enable-peridioc-full-compaction

1. append config to: `hadoop-ozone/dist/target/ozone-2.1.0-SNAPSHOT/compose/ozone/docker-config`
```
OZONE-SITE.XML_ozone.compaction.service.enabled=true
OZONE-SITE.XML_ozone.om.compaction.service.run.interval=1h
```

2. start testing with mixed workload
```bash
ozone sh volume create vol1
ozone sh bucket create /vol1/bucket1 --layout OBJECT_STORE
ozone freon omkeybench -n 100000000 -t 100 --size=0 --volume vol1 --bucket bucket1 --weights create:20,delete:8,list:1 --max-live-keys 25000
```

### 2025/6/10

![](a62c5c90bb415210ac6da2b47e2afbd9.excalidraw)

---

# SST Statistics-Based Intelligent RocksDB Compaction Optimization for Apache Ozone, a Next-Generation Distributed File System

**Author:** Chu-Cheng Li
**Supervising Professor:** Kun-Ta Chung

---

## Introduction

Apache Ozone is a next-generation distributed file system designed to overcome the small file limitations of traditional HDFS by using RocksDB for efficient metadata storage. This project introduces an **SST-based intelligent compaction optimization** to address RocksDB performance issues in Ozone, particularly under heavy delete workloads (tombstones).

**ozone:**

![](4b26ab21e8b4455d00abf4f9b239aa99.png)

![](efa6accac5b6ac959d02b21c3e268807.png)

**rocksdb:**

![](07ecec539c939d7a48dd550b96acc5da.png)

---

## Key Challenge

* **RocksDB suffers from slow iteration performance when many consecutive tombstones accumulate.**

### RocksDB Seek

![](63b766d97960b6f2084941fb6c88a95b.png)

1. **Candidate Table Selection:**
   The iterator consults the Summary (table min/max key) to quickly narrow down which tables might contain the target key.
2. **Key Search Across Levels:**
   Both MemTable (latest writes) and all levels of SSTables are scanned to find the smallest key ≥ target.
3. **Candidate Key Extraction:**
   The iterator fetches candidate keys from multiple sources in parallel.
4. **Heap Merge:**
   Results from each table are merged using a min-heap to return the next smallest key on every `Next()`.


### RocksDB Seek with Many Tombstone

![](5d8a0aa36c284f392c56aa79af7df589.png)

---

## Proposed Optimization:

### Scan Key Ranges with High Tombstone Density, then Compact Them

**Approach:**

* **Split the entire table into multiple small ranges** using bucket name prefixes.

  * Initially, each bucket forms a single range.
  * If a range becomes too large, **subdivide** it using SST table boundaries to create smaller, more manageable ranges.
* **Three main benefits:**

  1. Only compact SSTs with high tombstone ratios, reducing unnecessary resource usage.
  2. Compacting small SST ranges significantly lowers the impact on overall system performance.
  3. Enables **customized, optimized splitting logic** tailored to each table's characteristics and access patterns.

### Workflow

![](2e9cc83b1ad4d4db08bdc6dbff121ced.png)

---

### Architecture Diagram

![](81642f56172211e945a585cb9f072b89.png)

---

## Experimental Results

* **Enabling range compaction in Apache Ozone yields:**

  * **Read latency improvement:**

    * For a dataset with 10⁷ keys:

      * *Average seek latency reduced by over 200x* (from **357ms** to **1.7ms**)
      * *Maximum seek latency drops by 3.6x* (from **21.6ms** to **6.0ms**)
  * **Write throughput:**

    * Remains unaffected; normal data ingestion rates are maintained.
  * **Compaction resource usage:**

    * Average compaction time increases (from 5s to nearly 18s)
    * Compaction write size frequently spikes to 10MB+ (vs. <6MB without range compaction)

* **Conclusion:**
  This approach provides much more stable and predictable read performance while keeping write efficiency, at the cost of higher compaction overhead.

---

## Benchmark Workload

* **Total operations:** 8 × 10⁷

  * **Create:** 68.97%
  * **Delete:** 27.59%
  * **List:** 3.45%

---

## Visualizations


### Bytes Metrics
![](6ed4cc77c0b803dbb2f8a71b4c3ff8d1.png)
![](faba2657edd793a7059ef59a6cb761c9.png)

### Compaction Metrics
![](7917f1dec91aa77bdd56e7ae583efaf6.png)
![](6bf3ceec7bd084190ec335233c3db7e7.png)
![](a61b8340c89a1d9e7cc728fe1e019d7f.png)

### Read Metrics

#### Get 
![](16e245c79f20ffde35f6b6775105276a.png)
![](9664c874ee7012e71c147bb64624992e.png)
![](ae0f6891d70ce472a34d5efe83a0e866.png)
![](517d83ef443b0c13fa2b732fe90c27b6.png)

#### Seek

![](f05f2d9a1fb689179f4b968043071118.png)
![](b4bbb2a7c01c215a2064590acfba20fc.png)
![](653553246f742c51f319aef250853ea6.png)
![](72943746c00a80f951ed708eb0ba868b.png)
![](e61af6e5cb9dc19d0ec6249b2fd283a2.png)


### DeletedTable Metrics
![](9b341e036e856bebd4947813a6c819de.png)

### Flush Metrics
![](ec08376a204b1b1845199a4fd7517925.png)
![](356c5c06dad1a49c7f4c8cc3561ca80d.png)
![](8527418e8ca31010eeeaefd7ec9f48a8.png)

### KeyTable Metrics
![](55758848e1e1e9ce7cd3b92b377c7e5b.png)

### Number Metrics
![](6a6502c2a24fb77883b99964a934513c.png)
![](ea957106a9ece3d1903356e61f57e413.png)
![](8de25d5967faf87e033df49d49955761.png)
![](47086f3500ae69110efa8a52a8fdd501.png)

### SST Metrics
![](91238f6813eafa63e5075827417db462.png)
### Seel Latency vs Key count magnitude

![](808fe047b2440dfd9290273deeeccb22.png)


## Acknowledgements

This work was supervised by **Professor Kun-Ta Chung** and carried out as part of ongoing efforts to optimize metadata performance in Apache Ozone.

## Appendix

### Benchmark Setup

1. build ozone
2. clean old cluster and 

```bash
export COMPOSE_FILE=docker-compose.yaml:monitoring.yaml:profiling.yaml
OZONE_DATANODES=3 ./run.sh -d
```


---
## Reference

[1]: https://www.youtube.com/watch?v=ZeW6vH1YzHY&utm_source=chatgpt.com "Unlocking Scalable and Efficient Data Storage with Apache Ozone"
[2]: https://ozone.apache.org/docs/1.4.1/concept/datanodes.html?utm_source=chatgpt.com "Datanodes - Apache Ozone"

[3]: https://docs.cloudera.com/cdp-private-cloud-base/7.1.8/ozone-overview/ozone-overview.pdf?utm_source=chatgpt.com "[PDF] Apache Hadoop Ozone Overview - Cloudera Documentation"

[4]: https://www.cloudera.com/blog/technical/apache-ozone-metadata-explained.html?utm_source=chatgpt.com "Apache Ozone Metadata Explained | Blog - Cloudera"

[5]: https://osacon.io/slides/2023/OzoneArchitecture.pdf?utm_source=chatgpt.com "[PDF] Unlocking Scalable and Efficient Data Storage with Apache Ozone"


---

Need down sampling or smoothing:
- Bytes_read_per_second_comparison
- Bytes_write_per_second_comparison
- Compaction_read_bytes_comparison
- Compaction_write_bytes_comparison
- Flush_write_bytes_comparison
- Flush_write_median_latency_comparison
- Number_of_keys_read_per_second_comparison
- Number_of_keys_written_per_second_comparison
- Number_of_next_per_second_comparison
- Number_of_seeks_per_second_comparison
Need take log on y:
- Seek_average_latency_(μs)_comparison

---


