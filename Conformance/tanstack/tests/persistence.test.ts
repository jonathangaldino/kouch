import { describe, expect, it } from 'vitest'
import { MutationObserver, dehydrate } from '@tanstack/query-core'
import {
  persistQueryClient,
  persistQueryClientRestore,
  persistQueryClientSave,
  persistQueryClientSubscribe,
  removeOldestQuery,
} from '@tanstack/query-persist-client-core'
import { createAsyncStoragePersister } from '@tanstack/query-async-storage-persister'
import type { PersistedClient, Persister } from '@tanstack/query-persist-client-core'
import { advance, client, immediate, settle, T0 } from './helpers'

function memoryPersister(initial?: PersistedClient, restoreError?: Error) {
  let stored = initial
  const calls = { persist: 0, remove: 0 }
  const persister: Persister = {
    persistClient: (c) => { calls.persist++; stored = c },
    restoreClient: async () => { if (restoreError) throw restoreError; return stored },
    removeClient: () => { calls.remove++; stored = undefined },
  }
  return { persister, calls, get stored() { return stored } }
}

function snapshotWith(key: string, data: string, buster = ''): PersistedClient {
  const qc = client()
  qc.setQueryData([key], data)
  return { buster, timestamp: Date.now(), clientState: dehydrate(qc) }
}

function memoryStorage(failures = 0) {
  const map = new Map<string, string>()
  let writes = 0
  return {
    map,
    get writes() { return writes },
    storage: {
      getItem: async (k: string) => map.get(k) ?? null,
      setItem: async (k: string, v: string) => {
        writes++
        if (failures-- > 0) throw new Error('quota')
        map.set(k, v)
      },
      removeItem: async (k: string) => { map.delete(k) },
    },
  }
}

describe('persistence', () => {
  it('[per-001] save writes a timestamped snapshot', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    await advance(100)
    const m = memoryPersister()
    await persistQueryClientSave({ queryClient: qc, persister: m.persister, buster: 'v1' })
    expect(m.calls.persist).toBe(1)
    expect(m.stored!.buster).toBe('v1')
    expect(m.stored!.timestamp).toBe(T0 + 100)
    expect(m.stored!.clientState.queries.map((q) => [q.queryKey, q.state.data])).toEqual([[['a'], 'A']])
  })

  it('[per-002] restore hydrates the snapshot', async () => {
    const m = memoryPersister(snapshotWith('a', 'A'))
    const qc = client()
    await persistQueryClientRestore({ queryClient: qc, persister: m.persister })
    expect(qc.getQueryData(['a'])).toBe('A')
    expect(m.calls.remove).toBe(0)
  })

  it('[per-003] nothing persisted', async () => {
    const m = memoryPersister()
    const qc = client()
    await persistQueryClientRestore({ queryClient: qc, persister: m.persister })
    expect(qc.getQueryCache().getAll()).toHaveLength(0)
    expect(m.calls.remove).toBe(0)
  })

  it('[per-004] maxAge', async () => {
    const snapshot = snapshotWith('a', 'A')
    await advance(1000)
    const ok = memoryPersister(snapshot)
    const qc1 = client()
    await persistQueryClientRestore({ queryClient: qc1, persister: ok.persister, maxAge: 1000 })
    expect(qc1.getQueryData(['a'])).toBe('A')
    await advance(1)
    const old = memoryPersister(snapshot)
    const qc2 = client()
    await persistQueryClientRestore({ queryClient: qc2, persister: old.persister, maxAge: 1000 })
    expect(qc2.getQueryData(['a'])).toBeUndefined()
    expect(old.calls.remove).toBe(1)
  })

  it('[per-005] default maxAge is 24 hours', async () => {
    const snapshot = snapshotWith('a', 'A')
    await advance(24 * 3600 * 1000)
    const qc1 = client()
    await persistQueryClientRestore({ queryClient: qc1, persister: memoryPersister(snapshot).persister })
    expect(qc1.getQueryData(['a'])).toBe('A')
    await advance(1)
    const m = memoryPersister(snapshot)
    const qc2 = client()
    await persistQueryClientRestore({ queryClient: qc2, persister: m.persister })
    expect(qc2.getQueryData(['a'])).toBeUndefined()
    expect(m.calls.remove).toBe(1)
  })

  it('[per-006] buster mismatch discards the cache', async () => {
    const m = memoryPersister(snapshotWith('a', 'A', 'v1'))
    const qc = client()
    await persistQueryClientRestore({ queryClient: qc, persister: m.persister, buster: 'v2' })
    expect(qc.getQueryData(['a'])).toBeUndefined()
    expect(m.calls.remove).toBe(1)
  })

  it('[per-007] restore errors discard the cache', async () => {
    const E = new Error('corrupt')
    const m = memoryPersister(undefined, E)
    const qc = client()
    await expect(persistQueryClientRestore({ queryClient: qc, persister: m.persister })).rejects.toBe(E)
    expect(m.calls.remove).toBe(1)
  })

  it('[per-008] subscribe saves on every cache change', async () => {
    const qc = client()
    const m = memoryPersister()
    const unsubscribe = persistQueryClientSubscribe({ queryClient: qc, persister: m.persister })
    await qc.fetchQuery({ queryKey: ['a'], queryFn: immediate(() => 'A').fn })
    expect(m.calls.persist).toBe(3)
    await new MutationObserver(qc, { mutationFn: async () => 'ok' }).mutate(undefined)
    await settle()
    expect(m.calls.persist).toBe(6)
    unsubscribe()
    qc.setQueryData(['a'], 'B')
    await settle()
    expect(m.calls.persist).toBe(6)
  })

  it('[per-009] persistQueryClient restores first, then subscribes', async () => {
    const m = memoryPersister(snapshotWith('a', 'A'))
    const qc = client()
    const [, restored] = persistQueryClient({ queryClient: qc, persister: m.persister })
    await restored
    expect(qc.getQueryData(['a'])).toBe('A')
    expect(m.calls.persist).toBe(0)
    qc.setQueryData(['b'], 'B')
    expect(m.calls.persist).toBe(2)

    const m2 = memoryPersister(snapshotWith('a', 'A'))
    const qc2 = client()
    const [unsubscribe, restored2] = persistQueryClient({ queryClient: qc2, persister: m2.persister })
    unsubscribe()
    await restored2
    qc2.setQueryData(['b'], 'B')
    expect(m2.calls.persist).toBe(0)
  })

  it('[per-010] storage persister throttles writes', async () => {
    const s = memoryStorage()
    const persister = createAsyncStoragePersister({ storage: s.storage, throttleTime: 1000 })
    const c = (n: number): PersistedClient => ({ buster: `c${n}`, timestamp: Date.now(), clientState: { queries: [], mutations: [] } })
    void persister.persistClient(c(1))
    await settle()
    await advance(100)
    void persister.persistClient(c(2))
    await advance(100)
    void persister.persistClient(c(3))
    await settle()
    expect(s.writes).toBe(1)
    await advance(799)
    expect(s.writes).toBe(1)
    await advance(1)
    expect(s.writes).toBe(2)
    expect((await persister.restoreClient())!.buster).toBe('c3')
  })

  it('[per-011] storage persister round trip', async () => {
    const s = memoryStorage()
    const persister = createAsyncStoragePersister({ storage: s.storage })
    const c = snapshotWith('a', 'A', 'v1')
    await persister.persistClient(c)
    const restored = (await persister.restoreClient())!
    expect(restored.buster).toBe('v1')
    expect(restored.timestamp).toBe(c.timestamp)
    expect(restored.clientState.queries.map((q) => [q.queryKey, q.state.data])).toEqual([[['a'], 'A']])
    await persister.removeClient()
    expect(await persister.restoreClient()).toBeUndefined()
  })

  it('[per-012] storage persister retry: removeOldestQuery', async () => {
    const s = memoryStorage(1)
    const persister = createAsyncStoragePersister({ storage: s.storage, retry: removeOldestQuery })
    const qc = client()
    qc.setQueryData(['old'], 'O')
    await advance(100)
    qc.setQueryData(['new'], 'N')
    await persistQueryClientSave({ queryClient: qc, persister })
    await settle()
    expect(s.writes).toBe(2)
    expect((await persister.restoreClient())!.clientState.queries.map((q) => q.queryKey)).toEqual([['new']])
  })
})
