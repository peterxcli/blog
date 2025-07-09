---
title: "Ozone Snapshot 解析 1 - Snapshot Deep Clean & Reclaimable Filter"
summary: "深入解析 Apache Ozone Snapshot 的 Deep Clean 機制與 Reclaimable Filter 設計，說明如何安全高效地回收快照下的資料資源"
description: "深入解析 Apache Ozone Snapshot 的 Deep Clean 機制與 Reclaimable Filter 設計，說明如何安全高效地回收快照下的資料資源"
date: 2025-07-07T17:17:38+08:00
slug: "ozone-snapshot-deep-dive-1"
tags: ["ozone", "ozone-snapshot"]
# series: ["Documentation"]
# series_order: 9
cascade:
  showEdit: true
  showSummary: true
  hideFeatureImage: false
draft: false
---

## 前言

在 Ozone 裡，Snapshot 不只是把資料凍結下來而已。為了確保使用者可以還原歷史狀態、支援備份與異地複製等需求，我們必須做到「快照裡的東西能讀、不該被誤刪、但又不能一直佔著空間不放」。

這篇文章會從工程角度來看 Ozone Snapshot 是怎麼實作 Deep Clean：什麼資料可以被刪、哪些要留下？怎麼在 RocksDB Checkpoint 建好之後安全回收 deleted keys？Reclaimable Filter 怎麼幫忙做判斷？Deletion Service 怎麼針對每個 snapshot 一個個清？整個流程怎麼確保 snapshot 間的參照不會搞砸？

希望這篇可以讓你更清楚 Ozone Snapshot 背後怎麼動起來的，而不是只停在「有 snapshot 可以用」這種層次。

## Snapshot 可以做什麼

官網有教你怎麼使用 Ozone Snapshot: [Ozone Snapshot](https://ozone.apache.org/docs/edge/feature/snapshot.html)

有好幾篇詳細說明 ozone snapshot 可以做什麼的文章：
- [Introducing Apache Ozone Snapshots](https://medium.com/@prashantpogde/introducing-apache-ozone-snapshots-af82e976142f)：介紹 Ozone, Ozone Snapshot 的用處, 還提到 Clodera 自己出的 Replication Manager 可以利用 Ozone Snapshot 來做多 cluster 的資料 replication
- [Object Stores: The Case for Snapshots vs Object Versioning](https://medium.com/@prashantpogde/object-stores-the-case-for-snapshots-vs-object-versioning-d0b292742005)：比較 Ozone Snapshot 與傳統"物件版本管理"(Object Versioning)的不同。物件版本管理雖然能保留每個物件的多個版本，方便恢復誤刪或回溯，但會帶來 Namespace Explosion、版本垃圾回收(GC for Versions)、參照一致性(Referential Integrity and Consistency
)等管理難題，尤其在 Application 彼此之間有依賴關係時容易出現狀態不一致。Ozone 的 Snapshot 功能則針對整個物件群組（如一個 bucket）在特定時間點做應用一致性、只讀的 Snapshot ，避免版本數量過多、維護困難的問題，同時天然保障資料完整性和應用一致性。這讓應用程式在需要還原歷史狀態時更可靠、簡單，並大幅降低管理負擔。
- [Exploring Apache Ozone Snapshots](https://medium.com/@prashantpogde/exploring-apache-ozone-snapshots-d7989e1e6281)：粗略介紹 Ozone Snapshot 有哪些功能：(1. 支援使用者在 bucket 層級進行 Snapshot 操作，讓你可以在任意時刻快速凍結、保存 bucket 當下的狀態。(2.  Snapshot 操作即時完成，並可透過專屬的檔案系統路徑直接存取 Snapshot 內容。(3. 使用者可列出所有 Snapshot 、**比對不同 Snapshot 間的差異(Snapshot Diff)**，甚至從 Snapshot 還原資料。(4. Snapshot 為唯讀、可獨立刪除，也不會因主存儲區資料被刪除而失效。

    空間用量則會根據 Snapshot 間實際差異而增長，並不會重複儲存沒有變動的部分。
- [Apache Ozone Snapshots: Addressing Different Use Cases](https://medium.com/@prashantpogde/apache-ozone-snapshots-addressing-different-use-cases-ba6b98f8b94d)：各種 Snapshot Use Case, 包括：**Data Protection**(Failed Transactions, Ransomware, Malware State), **Time Travel**, **Data Replication and Remote Replication**, **Archival and Compliance**, **Incremental Analytics** and **Generative AI**(嗯？)
- [Apache Ozone Using the Snapshot Feature](https://medium.com/@prashantpogde/apache-ozone-using-the-snapshot-feature-7ced5f15b81a)：教你怎麼在 Ozone 裡 CRUD Snapshot, Snapshot Rename 還有 Snapshot Diff

![Snapshot Space Efficiency](snapshot-space-efficiency.png)

## Ozone Snapshot 與 RocksDB Checkpoint

Ozone Snapshot 的實作主要依賴 RocksDB 的 Checkpoint 功能。

然後 RocksDB Checkpoint 是 RocksDB 提供的一種高效資料 Snapshot 機制。它的核心原理是：在不複製資料的情況下，快速產生一份資料庫當前狀態的「一致性 Snapshot 」。這個 Snapshot 本質上是一個新的資料目錄，裡面大多數檔案（如 SST 檔案）都是透過 hard link 指向原本的 SST Files，因此**建立速度極快且不佔用額外空間**。

不過這種 hard link 的機制也會有限制, 像是大部分的 filesystem 最多能對一個檔案建立 65535 個 hard link

## Metadata of Snapshot

### Snapshot Info

Ozone 用 [`SnapshotInfo`](https://github.com/apache/ozone/blob/3bfb7affaf860ae0957fea2b2058ab50a85f571d/hadoop-ozone/common/src/main/java/org/apache/hadoop/ozone/om/helpers/SnapshotInfo.java) 作為每個 Snapshot 的 metadata：

裡面含有的資訊有:
- `UUID snapshotId`：這個 snapshot 的 uuid
- `String name`：snapshot 名稱
- `String volumeName`：snapshot 所屬的 volume
- `String bucketName`：snapshot 所屬的 bucket
- `SnapshotStatus snapshotStatus`：snapshot 狀態（ACTIVE 或 DELETED）
- `long creationTime`：建立時間
- `long deletionTime`：刪除時間
- `UUID pathPreviousSnapshotId`：同路徑（bucket prefix）下的前一個 snapshot, 與 [Snapshot Chain](#snapshot-chain) 有關
- `UUID globalPreviousSnapshotId`：全域的前一個 snapshot, 也與 [Snapshot Chain](#snapshot-chain) 有關
- `String checkpointDir`：RocksDB checkpoint 目錄
- `long dbTxSequenceNumber`：RocksDB 序列號
- `boolean deepClean`：是否已執行深度清理
- `boolean sstFiltered`：是否已過濾 SST 檔案
- `long referencedSize`：這個 snapshot 的資料大小（以 bytes 為單位), 資料指的是 data blocks 的資料大小, 不是這個 rocksdb checkpoint 在 OM 的 Disk 上佔的大小
- `long referencedReplicatedSize`：同上，但考慮了 replication 或 Erasure Coding 後的實際儲存空間, 但這個空間大小是估計的, 並沒有實際根據每個 key 的 data size & replication policy 去計算, 不然太慢了
- `long exclusiveSize`：這個 snapshot「獨佔」的資料大小（以 bytes 為單位），也就是只屬於這個 snapshot、其他 snapshot 都沒有的資料量。這個"獨佔"的概念在 [Reclaimable Filter](#reclaimable-filter) 中會提到
- `long exclusiveReplicatedSize`： 同上，但考慮了 replication 或 Erasure Coding 後的實際儲存空間。例如，三副本下 `exclusiveSize=1000`，`exclusiveReplicatedSize=3000`。
- `boolean deepCleanedDeletedDir`：是否已經 deep clean 過 snapshot 裡的 deletedDirectoryTable

### Snapshot Chain

Ozone 使用兩種 snapshot chain 來管理 snapshot：

```java
public class SnapshotChainManager {
    // global snapshot chain：所有 snapshot 按時間順序連接
    private Map<String, SnapshotChainInfo> globalSnapshotChain; // synchronizedMap
    
    // path snapshot chain：每個 volume/bucket 維護自己的 snapshot chain (按照時間順序連接)
    private ConcurrentMap<String, LinkedHashMap<UUID, SnapshotChainInfo>>
      snapshotChainByPath;
}
```

[`SnapshotChainInfo`](https://github.com/apache/ozone/blob/3bfb7affaf860ae0957fea2b2058ab50a85f571d/hadoop-ozone/ozone-manager/src/main/java/org/apache/hadoop/ozone/om/SnapshotChainInfo.java) 裡有 `previousSnapshotId` 和 `nextSnapshotId` 來維護 snapshot chain 的雙向連結。

![Snapshot Chain](snapshot-chain.png)

## AOS/AFS

AOS 是 Active Object Store 的縮寫, AFS 是 Active File System 的縮寫, 其實就是指正常 RocksDB 的 DB instance, 會有這個名詞主要是和 Snapshot 做出區分。

## Snapshot 建立流程詳解

### 建立前的驗證

```java
public OMRequest preExecute(OzoneManager ozoneManager) {
    // 1. 驗證 Snapshot 名稱合法性
    validateSnapshotName(snapshotName);
    
    // 2. 檢查使用者權限（只有 bucket owner 和 admin 可以建立）
    checkAcls(ozoneManager, volumeName, bucketName, userName);
    
    // 3. 檢查 Snapshot 數量限制
    if (getSnapshotCount() >= maxSnapshotLimit) {
        throw new OMException("Snapshot limit exceeded");
    }
    
    // 4. 生成唯一的 snapshot ID
    UUID snapshotId = UUID.randomUUID();
}
```

### RocksDB Checkpoint 建立

![Snapshot Creation](snapshot-checkpoint.png)

這是 Snapshot 建立的核心步驟，利用 RocksDB 的 checkpoint 功能：


1. 強制刷新 WAL 和 MemTable 到磁碟

    因為 Checkpoint 是透過對當前 SST Files 建立 hard link 來達成，所以需要先強制刷新 WAL 和 MemTable 到磁碟，確保 SST Files 是有包含最新的資料。

```java
// Flush the DB WAL and mem table.
db.flushWal(true);
db.flush();

checkpoint.createCheckpoint(checkpointPath);
``` 

    
2. 清理 Snapshot 範圍內的已刪除資料

    Ozone 在刪除 key or file 的時候不會直接刪除, 而是會先將其記錄在 `deletedTable` 和 `deletedDirectoryTable` 中, 在建立 Snapshot 時, 因為 `deletedTable` 和 `deletedDirectoryTable` 的內容都已經被紀錄到該 snapshot 中, 所以可以把這兩個 table 都清空, 這也讓後續的 DeletingService/ReclaimableFilter 可以更輕鬆的處理 GC/Deep Clean, 因為每個 snapshot 的 `deletedTable`/`deletedDirectoryTable` 的內容一定不會重複。

```java
// Clean up active DB's deletedTable right after checkpoint is taken,
// There is no need to take any lock as of now, because transactions are flushed sequentially.
deleteKeysFromDelKeyTableInSnapshotScope(omMetadataManager,
    snapshotInfo.getVolumeName(), snapshotInfo.getBucketName(), batchOperation);
// Clean up deletedDirectoryTable as well
deleteKeysFromDelDirTableInSnapshotScope(omMetadataManager,
    snapshotInfo.getVolumeName(), snapshotInfo.getBucketName(), batchOperation);
```

### Lock Protection

需要鎖來保護 data race: 在 Bucket Lock 上 Read Lock 來保護 bucket 不被刪除, 以及 Snapshot Lock 上 Write Lock 來保護 snapshot chain 的 path snapshot chain。

```java
// Lock bucket so it doesn't
//  get deleted while creating snapshot
mergeOmLockDetails(
    omMetadataManager.getLock().acquireReadLock(BUCKET_LOCK,
        volumeName, bucketName));
acquiredBucketLock = getOmLockDetails().isLockAcquired();

mergeOmLockDetails(
    omMetadataManager.getLock().acquireWriteLock(SNAPSHOT_LOCK,
        volumeName, bucketName, snapshotName));
acquiredSnapshotLock = getOmLockDetails().isLockAcquired();
```

還有 Snapshot 的建立過程必須保證原子性，避免部分成功的情況, 

因為 Snapshot 建立時, 會涉及多個元件(Snapshot Chain Manager, Snapshot Info Table)所以如果過程中發生錯誤, 需要把變更的資料都還原。

#### OzoneManagerLock

我們是用一個自己寫的 lock manager [OzoneManagerLock](https://github.com/apache/ozone/blob/9b713d0b6594785872090cd78798a0931779f630/hadoop-ozone/common/src/main/java/org/apache/hadoop/ozone/om/lock/OzoneManagerLock.java) 來上鎖

它是由 Striped Lock + Level Lock 組成

Striped Lock 可以對 stripe lock 可以管理不同的 key 各自的鎖 提供小顆粒度的鎖, 是用來保護具體的資源(如 bucket prefix(`volume1/bucket1`)、key prefix(`volume1/bucket1/key1`) 等) 

```java
Striped<ReadWriteLock> stripedLock;
```

#### Level Lock

雖然 Stripe Lock 已經可以根據各種 bucket prefix/key prefix 來提供細粒度的鎖，但這只是解決了**不同資源之間的並發問題**。還有一個重要的問題需要解決：**同一 thread 內的操作順序和 Resource Level Constraint**。

比方說，對於 `/volume1/bucket1` 這個 prefix，一個線程可能會同時操作多種不同層級的資源：
- **Bucket 層級**：修改 bucket 的配置、ACL 等
- **Key 層級**：讀寫 bucket 內的 key
- **Snapshot 層級**：創建或刪除 snapshot

如果沒有 level constraint，可能會出現問題：
```java
// 錯誤的操作順序：先操作 key，再操作 bucket
lock.acquireWriteLock(KEY_PATH_LOCK, "volume1", "bucket1", "key1");
// 此時如果嘗試修改 bucket 配置，可能會導致數據不一致
lock.acquireWriteLock(BUCKET_LOCK, "volume1", "bucket1");  // 應該 throw exception
```

所以我們需要 **Level Lock** 來根據資源的優先級（priority）來決定同一線程內哪些資源可以成功獲取鎖。Ozone 定義的資源優先級：

{{< codeimporter url="https://raw.githubusercontent.com/apache/ozone/9b713d0b6594785872090cd78798a0931779f630/hadoop-ozone/common/src/main/java/org/apache/hadoop/ozone/om/lock/OzoneManagerLock.java" type="java" startLine="699" endLine="716" >}}

Level Lock 使用 **bit mask** 實作，每個線程都有自己獨立的鎖狀態，不同線程之間的 level 的 constraint 是相互獨立的。

透過這種設計, 我們可以確保在同一個 thread 內, 資源的獲取順序是正確的, 不會出現死鎖的問題。

## DeletingService / Deep Clean

Ozone 的 Deep Clean 機制，主要依賴兩個背景服務：`KeyDeletingService` 與 `DirectoryDeletingService`。這兩個服務會定期掃描 OM metadata，將已標記刪除但尚未真正回收的 key 與目錄，根據 snapshot chain 的狀態進行安全的回收與物理刪除。

### Deep Clean for Snapshots

Ozone 的 Deletion Service（包含 `KeyDeletingService` 與 `DirectoryDeletingService`）**會針對每一個 snapshot 都做 deep clean**，而不是只針對 active DB（AOS）進行。這是 Ozone snapshot 空間回收機制的核心設計之一。

舉例來說，`DirectoryDeletingService` 的 `getTasks()` 方法會自動為每個 snapshot 建立一個 background task：

```java
@Override
public BackgroundTaskQueue getTasks() {
  BackgroundTaskQueue queue = new BackgroundTaskQueue();
  queue.add(new DirDeletingTask(null)); // 針對 active object store (AOS)
  if (deepCleanSnapshots) {
    Iterator<UUID> iterator = snapshotChainManager.iterator(true);
    while (iterator.hasNext()) {
      UUID snapshotId = iterator.next();
      queue.add(new DirDeletingTask(snapshotId)); // 針對每個 snapshot
    }
  }
  return queue;
}
```

一開始先把 `DirDeletingTask(null)` 放進 queue 是為了讓 DeletingService 對 active DB 進行 deep clean, 之後再針對每個 snapshot 進行 deep clean(依照 snapshot chain 的順序)。

同理，`KeyDeletingService` 也是這樣

這種設計的好處是：**每個 snapshot 都能獨立進行 deep clean，確保即使 snapshot chain 很長、snapshot 之間的資料參照複雜，也能安全且高效地回收空間**。而且每個 snapshot 的 deep clean 狀態（如 `deepCleanedDeletedDir`、`deepCleanedDeletedKey`）都會被單獨追蹤，只有當該 snapshot 的所有 deleted directory 或 key 都被安全回收後，才會標記為 deep clean 完成。

> 這也意味著，Ozone 的 Deletion Service 並不是「全域一次性」的清理，而是「針對每個 snapshot 逐一進行」的細緻回收，這對於大規模物件儲存系統的 snapshot 管理來說，是非常關鍵的設計。

### KeyDeletingService

就是遍歷 snapshotRenamedTable 和 deletedTable, 然後用 [reclaimable filter](#reclaimable-filter) 過濾出可以回收的 key, 然後再發送給 SCM 進行物理刪除。
(SCM 是 Storage Container Manager 的縮寫, 是所有 Data Nodes 的老大, 然後 Data Nodeㄋ 上儲存著一堆 data blocks, 也就是真實的檔案內容, 並且一群連續得 data blocks 會再組成一個叫 Container 的單位, 不是那個 Linux Container..。 總之想了解這塊的話也可以留言叫我寫一篇介紹那部分的文章ㄏㄏ)

1. 遍歷 snapshotRenamedTable 和 deletedTable, 然後用 reclaimable filter 過濾出可以回收的 key：

```java
List<String> renamedTableEntries =
    keyManager.getRenamesKeyEntries(volume, bucket, null, renameEntryFilter, remainNum).stream()
        .map(Table.KeyValue::getKey)
        .collect(Collectors.toList());
remainNum -= renamedTableEntries.size();

// Get pending keys that can be deleted
PendingKeysDeletion pendingKeysDeletion = currentSnapshotInfo == null
    ? keyManager.getPendingDeletionKeys(reclaimableKeyFilter, remainNum)
    : keyManager.getPendingDeletionKeys(volume, bucket, null, reclaimableKeyFilter, remainNum);
```
可以注意到這裡有個 `remainNum` 的參數，這是為了避免一次過濾太多 key, 拿來做 pagination 的。

2. 發送給 SCM 進行物理刪除：

```java
  Pair<Integer, Boolean> processKeyDeletes(List<BlockGroup> keyBlocksList,
      Map<String, RepeatedOmKeyInfo> keysToModify, List<String> renameEntries,
      String snapTableKey, UUID expectedPreviousSnapshotId) throws IOException {
    ...
    // 跟 SCM 說哪些 blocks 可以被刪除
    List<DeleteBlockGroupResult> blockDeletionResults = scmClient.deleteKeyBlocks(keyBlocksList);
    ...
    // SCM 回報成功後, 再發送 purge keys request 給 OM, 然後 keys 才會真正從 OM DB 中消失
    purgeResult = submitPurgeKeysRequest(blockDeletionResults,
          keysToModify, renameEntries, snapTableKey, expectedPreviousSnapshotId);
    ...
    return purgeResult;
  }
```


3. 當一個 snapshot 的所有 key 都被安全回收後, 更新該 snapshot 的 deep clean 標記：

```java
if (currentSnapshotInfo != null) {
  setSnapshotPropertyRequests.add(OzoneManagerProtocolProtos.SetSnapshotPropertyRequest.newBuilder()
      .setSnapshotKey(snapshotTableKey)
      .setDeepCleanedDeletedKey(true)
      .build());
}
submitSetSnapshotRequests(setSnapshotPropertyRequests);
```

這代表該 snapshot 的 key 已經完成 deep clean，後續可以安全地釋放空間。

### DirectoryDeletingService

`DirectoryDeletingService` 則負責回收已刪除的目錄（以及其下的所有子目錄與檔案）。它的運作方式與 `KeyDeletingService` 類似, 多了遞迴處理目錄樹的邏輯

遞迴處理目錄樹的邏輯：

```java
private Optional<PurgePathRequest> prepareDeleteDirRequest(
    OmKeyInfo pendingDeletedDirInfo, String delDirName, boolean purgeDir,
    List<Pair<String, OmKeyInfo>> subDirList,
    KeyManager keyManager,
    CheckedFunction<Table.KeyValue<String, OmKeyInfo>, Boolean, IOException> reclaimableFileFilter,
    long remainingBufLimit) throws IOException {
    
    // step-1: 取得該目錄下的所有子目錄
    DeleteKeysResult subDirDeleteResult =
        keyManager.getPendingDeletionSubDirs(volumeId, bucketId,
            pendingDeletedDirInfo, keyInfo -> true, remainingBufLimit);
    List<OmKeyInfo> subDirs = subDirDeleteResult.getKeysToDelete();
    
    // 將子目錄加入待處理清單，以便下次迭代處理, 再次展開處理
    for (OmKeyInfo dirInfo : subDirs) {
        String ozoneDeleteKey = omMetadataManager.getOzoneDeletePathKey(
            dirInfo.getObjectID(), ozoneDbKey);
        subDirList.add(Pair.of(ozoneDeleteKey, dirInfo));
    }
    
    // step-2: 取得該目錄下的所有子檔案
    DeleteKeysResult subFileDeleteResult =
        keyManager.getPendingDeletionSubFiles(volumeId, bucketId,
            pendingDeletedDirInfo, keyInfo -> purgeDir || reclaimableFileFilter.apply(keyInfo), remainingBufLimit);
    List<OmKeyInfo> subFiles = subFileDeleteResult.getKeysToDelete();
    
    // step-3: 只有當子目錄和子檔案都處理完畢時，才刪除父目錄
    String purgeDeletedDir = purgeDir && subDirDeleteResult.isProcessedKeys() &&
        subFileDeleteResult.isProcessedKeys() ? delDirName : null;
}
```

## Reclaimable Filter

### 什麼是 Reclaimable Filter？

Ozone 裡在刪除 key 或 directory 時, 不會直接刪除, 而是會先將其記錄在 `deletedTable` 和 `deletedDirectoryTable` 中, 然後會有 `DeletingService` 會在背景定期批次的把這些被刪除的 key 告訴 SCM 去刪除哪些 data node 上的 block。
(SCM 是 Storage Container Manager 的縮寫, 是所有 Data Nodes 的老大)

因為 Snapshot 允許使用者直接讀取 snapshot 裡的 key, 所以假設某個 snapshot 裡面的 key1 還可以被讀到, 但 AOS 上的刪除造成該 key1 在 datanode 上的資料被刪除, 這樣會讓使用者在讀取該 snapshot 的 key1, 發現根本讀不到他的 data blocks 的資料, 很不直覺吧?

所以 DeletingService 在提交給 SCM 批次刪除的同時, 不能盲目的亂刪亂給, 需要 **Snapshot-Aware**

Reclaimable Filter 正是為了這個目的而設計的, 它會在 DeletingService 提交給 SCM 批次刪除的同時, 去過濾哪些 key 或 directory 可以被回收。

~~其實原本沒有 Reclaimable Filter 這個東西, 只是這邊的 code 實在太醜了, 所以才用 Reclaimable Filter 去把 DeletingService Snapshot-Aware 的邏輯們封裝起來~~

![Reclaimable Filter](snapshot-aware-key-reclaimation.png)

### ReclaimableFilter Abstract Class

[`ReclaimableFilter`](https://github.com/apache/ozone/blob/9b713d0b6594785872090cd78798a0931779f630/hadoop-ozone/ozone-manager/src/main/java/org/apache/hadoop/ozone/om/snapshot/filter/ReclaimableFilter.java) 提供了一個通用的 filter reclaimable resource by snapshot 框架。

你可以指定要檢查當前 snapshot 之前的 N 個 snapshot，`ReclaimableFilter` 會自動鎖定這些 snapshot，並在每次判斷時確保 [snapshot chain](#snapshot-chain) 的一致性。具體的回收判斷邏輯則由各種 Subclass 實作，而 `ReclaimableFilter` 本身只負責 snapshot 資料的準備、 lock 跟資源管理(explicitly close)。

### 各種 Reclaimable Filter 的 Subclass 的邏輯

`ReclaimableFilter` 已經幫我們打下很好的基礎了, 我們現在只需要針對每種資源去寫下對應的 reclaimable 邏輯即可。

#### [ReclaimableKeyFilter](https://github.com/apache/ozone/blob/9b713d0b6594785872090cd78798a0931779f630/hadoop-ozone/ozone-manager/src/main/java/org/apache/hadoop/ozone/om/snapshot/filter/ReclaimableKeyFilter.java)
用於過濾可回收的檔案 key，需要檢查前兩個 snapshot：

```java
public class ReclaimableKeyFilter extends ReclaimableFilter<OmKeyInfo> {
    public ReclaimableKeyFilter(/* ... */) {
        super(/* ... */, 2); // 需要檢查前 2 個 snapshot
    }
}
```

- 如果這個 key 在前一個 snapshot 中找不到，就會被標記為「可回收」。
- 如果在前一個 snapshot 中找得到，則會進一步檢查「前前一個 snapshot」，以確認這個 key 是否只存在於前一個 snapshot，並將其大小計入前一個 snapshot 的 exclusive size 統計。


#### [ReclaimableDirFilter](https://github.com/apache/ozone/blob/9b713d0b6594785872090cd78798a0931779f630/hadoop-ozone/ozone-manager/src/main/java/org/apache/hadoop/ozone/om/snapshot/filter/ReclaimableDirFilter.java)
用於過濾可回收的目錄，只需要檢查前一個 snapshot：

(Directory 是 Ozone 的其中一種 Object Layout - FileSystem Optimized 的其中一員, FSO layout 具有更高效的 rename, delete 的效能, 詳細可以參考 [Prefix based File System Optimization](https://ozone.apache.org/docs/edge/feature/prefixfso.html))

```java
public class ReclaimableDirFilter extends ReclaimableFilter<OmKeyInfo> {
    public ReclaimableDirFilter(/* ... */) {
        super(/* ... */, 1); // 只需要檢查前 1 個 snapshot
    }
}
```

- 如果前一個 Snapshot 不存在（例如 Snapshot 已被刪除），那這個目錄就可以直接回收。
- 如果前一個 Snapshot 存在，會去查詢這個目錄在前一個 snapshot 中的資訊（`OmDirectoryInfo`）：
   - 如果查不到這個目錄, 代表這個目錄在前一個 snapshot 中已經不存在, 可以回收。
   - 如果查得到, 但 `objectID` 不同, 代表這個目錄在前一個 snapshot 中已經被覆蓋或變更, 也可以回收。
   - 只有當前一個 snapshot 中有相同 `objectID` 的目錄時, 才不能回收。

#### [ReclaimableRenameEntryFilter](https://github.com/apache/ozone/blob/9b713d0b6594785872090cd78798a0931779f630/hadoop-ozone/ozone-manager/src/main/java/org/apache/hadoop/ozone/om/snapshot/filter/ReclaimableRenameEntryFilter.java)
用來 filter reclaimable 的 snapshot rename entry

- What is rename entry?

    當你對一個 key/dir 執行 rename 時，如果該 bucket 處於 snapshot scope，為了後續的 Snapshot Diff, GC/Deep Clean 等操作能夠正確追蹤這個物件的歷史, 則會在 snapshotRenamedTable 裡新增一筆紀錄, 其結構是：

    - `Key`：`/volumeName/bucketName/objectID`（`objectID` 代表被 rename 的 key 或 dir 的 unique ID）
    - `Value`：rename 前的 key/dir 路徑

```java
public class ReclaimableRenameEntryFilter extends ReclaimableFilter<String> {
    public ReclaimableRenameEntryFilter(/* ... */) {
        super(/* ... */, 1); // 只需要檢查前 1 個 snapshot
    }
}
```

- 如果在前一個 Snapshot 中查不到這個 objectId，代表已經沒有人參照這個 rename entry，可以回收。
- 如果查得到，代表還有 Snapshot 參照這個 objectId，不能回收。

### 小結

奇犽

其實各種 Reclaimable Filter 主要都只是看前一個 snapshot 的資料, 來決定是否 reclaimable

只有 [ReclaimableKeyFilter](#reclaimablekeyfilter) 需要再多看一個 snapshot, 去把正確的 exclusive size 計算出來。

還有就是, 你可能在上面看到我說只要 snapshot 裡面有這個 key/dir/rename entry 就代表不能回收這件事的時候，
覺得這要實作感覺很費時, 感覺就要一個一個 snapshot 去檢查,
但實際上你仔細用應該是歸納法想想就會發現, 其實只要看前一個 snapshot 的資料, 就可以知道哪些資源可以回收, 哪些資源不能回收。


## 結語

這篇文章主要介紹了 Ozone Snapshot 的 Deep Clean 跟 Reclaimable Filter 怎麼運作：從 deletedTable / deletedDirectoryTable 的資料怎麼挑、怎麼判斷哪些 key 可以刪、到 DeletingService 怎麼配合 snapshot chain 一個個清、最後再加上 snapshot 的 exclusive size 統計。

但 Deep Clean 只是 Ozone Snapshot 管理中的一環, 下一篇 **Ozone Snapshot 解析 2 - Snapshot Deleting Service & SST Files Filtering & Snapshot Diff** 會探討怎麼用 SST Files Filtering 來把與各 Snapshot 不相關的資料去蕪存清, 以及 Snapshot Deleting Service 在刪除 snapshot 時, 怎麼處理 snapshot aware reclaimable resource 的 cases, 還有最重要的主角- Snapshot Diff - 是怎麼克服 compaction churn 並計算出任意兩個 snapshot 間的變更 - `+` (add), `-` (delete), `M` (modify), `R` (rename)。

如果寫得出來而且塞得下的話...


## Reference

- [Snapshots for an Object Store](https://www.youtube.com/watch?v=7_FrTClCUag)
- [Improving Snapshot Scale](https://docs.google.com/document/d/1Xw1AtKAlDm97UiLXd8egjeLIaYq4rpClv1xD7x5Xvww/edit?tab=t.0#heading=h.c9lecgual3zk)
- [Ozone Snapshot Deletion & Garbage Collection](https://issues.apache.org/jira/browse/HDDS-7730)
- [Design: Ozone Snapshot Deletion Garbage Collection based on key deletedTable](https://fossil-i.notion.site/Design-Ozone-Snapshot-Deletion-Garbage-Collection-based-on-key-deletedTable-2a624480dc7c4bc3ad608cbf86a25541)
