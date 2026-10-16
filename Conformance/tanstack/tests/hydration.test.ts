import { describe, expect, it } from 'vitest'
import { dehydrate, hydrate, MutationObserver, onlineManager } from '@tanstack/query-core'
import { advance, client, controlled, failing, immediate, observe, settle, T0 } from './helpers'

describe('hydration', () => {
  it('[hyd-001] dehydrate keeps successful queries by default', async () => {
    const qc = client()
    qc.setQueryData(['ok'], 'A')
    void qc.prefetchQuery({ queryKey: ['pending'], queryFn: controlled().fn })
    await qc.prefetchQuery({ queryKey: ['bad'], queryFn: failing().fn })
    await advance(100)
    const snapshot = dehydrate(qc)
    expect(snapshot.queries).toHaveLength(1)
    const q = snapshot.queries[0]!
    expect(q.queryKey).toEqual(['ok'])
    expect(q.state.data).toBe('A')
    expect(q.state.dataUpdatedAt).toBe(T0)
    expect(q.state.status).toBe('success')
    expect(q.dehydratedAt).toBe(T0 + 100)
  })

  it('[hyd-002] hydrate creates idle queries without fetching', async () => {
    const source = client()
    source.setQueryData(['ok'], 'A')
    const snapshot = dehydrate(source)
    const qc = client()
    hydrate(qc, snapshot)
    await settle()
    const s = qc.getQueryState(['ok'])!
    expect(qc.getQueryData(['ok'])).toBe('A')
    expect(s.dataUpdatedAt).toBe(T0)
    expect(s.status).toBe('success')
    expect(s.fetchStatus).toBe('idle')
    expect(qc.isFetching()).toBe(0)
  })

  it('[hyd-003] older snapshots do not overwrite newer data', async () => {
    const source = client()
    source.setQueryData(['ok'], 'old')
    const snapshot = dehydrate(source)
    await advance(1000)
    const qc = client()
    qc.setQueryData(['ok'], 'new')
    hydrate(qc, snapshot)
    expect(qc.getQueryData(['ok'])).toBe('new')
  })

  it('[hyd-004] newer snapshots overwrite older data', async () => {
    const qc = client()
    qc.setQueryData(['ok'], 'old')
    await advance(1000)
    const source = client()
    source.setQueryData(['ok'], 'new')
    hydrate(qc, dehydrate(source))
    expect(qc.getQueryData(['ok'])).toBe('new')
    expect(qc.getQueryState(['ok'])!.dataUpdatedAt).toBe(T0 + 1000)
  })

  it('[hyd-005] shouldDehydrateQuery', async () => {
    const source = client()
    await source.prefetchQuery({ queryKey: ['bad'], queryFn: failing().fn })
    const snapshot = dehydrate(source, { shouldDehydrateQuery: () => true })
    expect(snapshot.queries.map((q) => [q.queryKey, q.state.status])).toEqual([[['bad'], 'error']])
    const qc = client()
    hydrate(qc, snapshot)
    expect(qc.getQueryState(['bad'])!.status).toBe('error')
  })

  it('[hyd-006] hydrated data keeps its age', async () => {
    const source = client()
    source.setQueryData(['ok'], 'A')
    const snapshot = dehydrate(source)
    await advance(5000)
    const qc1 = client()
    hydrate(qc1, snapshot)
    const f1 = immediate(() => 'B')
    observe(qc1, { queryKey: ['ok'], queryFn: f1.fn, staleTime: 1000 })
    await settle()
    expect(f1.count).toBe(1)
    const qc2 = client()
    hydrate(qc2, snapshot)
    const f2 = immediate(() => 'B')
    observe(qc2, { queryKey: ['ok'], queryFn: f2.fn, staleTime: 10_000 })
    await settle()
    expect(f2.count).toBe(0)
  })

  it('[hyd-007] serializeData / deserializeData', () => {
    const source = client()
    source.setQueryData(['ok'], 'A')
    const snapshot = dehydrate(source, { serializeData: (d) => d + '|s' })
    expect(snapshot.queries[0]!.state.data).toBe('A|s')
    const qc = client()
    hydrate(qc, snapshot, { defaultOptions: { deserializeData: (d) => d + '|d' } })
    expect(qc.getQueryData(['ok'])).toBe('A|s|d')
  })

  it('[hyd-008] paused mutations survive dehydration', async () => {
    const source = client()
    await new MutationObserver(source, { mutationKey: ['done'], mutationFn: async () => 'ok' }).mutate(undefined)
    onlineManager.setOnline(false)
    void new MutationObserver(source, { mutationKey: ['add'], mutationFn: async () => 'x' }).mutate('v')
    await settle()
    const snapshot = dehydrate(source)
    expect(snapshot.mutations).toHaveLength(1)
    const m = snapshot.mutations[0]!
    expect(m.mutationKey).toEqual(['add'])
    expect(m.state.isPaused).toBe(true)
    expect(m.state.variables).toBe('v')

    const qc = client()
    const received: unknown[] = []
    qc.setMutationDefaults(['add'], { mutationFn: async (v: unknown) => { received.push(v); return 'added' } })
    hydrate(qc, snapshot)
    onlineManager.setOnline(true)
    await qc.resumePausedMutations()
    await settle()
    expect(received).toEqual(['v'])
    expect(qc.getMutationCache().getAll()[0]!.state.status).toBe('success')
  })

  it('[hyd-009] hydrate default options', async () => {
    const source = client()
    source.setQueryData(['ok'], 'A')
    const qc = client()
    hydrate(qc, dehydrate(source), { defaultOptions: { queries: { gcTime: 1000 } } })
    await advance(999)
    expect(qc.getQueryCache().find({ queryKey: ['ok'] })).toBeDefined()
    await advance(1)
    expect(qc.getQueryCache().find({ queryKey: ['ok'] })).toBeUndefined()
  })
})
